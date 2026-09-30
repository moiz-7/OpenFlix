import CryptoKit
import Foundation
import OpenFlixKit

/// A standing permission one agent holds over the HTTP bridge.
///
/// Issued only by a person at this machine (`openflix agents grant`), never
/// over the bridge itself. It names which kinds of action the agent may take —
/// by effect, so "may read the library" and "may spend money" are separate
/// decisions — and how much it may spend per day. The cap is the hard
/// guarantee on this side: an agent host's own approval step (Harbor asks its
/// owner in Telegram) is a guarantee this process cannot verify.
struct AgentGrant: Codable, Equatable {
    /// Identifier grammar, like every other id here. Shows up in logs.
    var name: String
    /// Hex SHA-256 of the bearer token. The token itself is shown once, at
    /// grant time, and never stored.
    var tokenHash: String
    var effects: [ActionEffect]
    /// Spend ceiling per local calendar day, in USD. Zero means no spending,
    /// whatever `effects` says.
    var dailyCapUSD: Double
    var createdAt: Date
    var expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case name, effects
        case tokenHash = "token_hash"
        case dailyCapUSD = "daily_cap_usd"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }

    func allows(_ effect: ActionEffect) -> Bool {
        effects.contains(effect) && (effect != .spend || dailyCapUSD > 0)
    }

    func isExpired(at now: Date = Date()) -> Bool {
        expiresAt.map { $0 <= now } ?? false
    }

    /// What `openflix agents list` shows. Never the hash.
    func summary(spentToday: Double) -> [String: Any] {
        var d: [String: Any] = [
            "name": name,
            "effects": effects.map(\.rawValue),
            "daily_cap_usd": dailyCapUSD,
            "spent_today_usd": (spentToday * 10_000).rounded() / 10_000,
            "created_at": ISO8601DateFormatter().string(from: createdAt),
        ]
        if let expiresAt { d["expires_at"] = ISO8601DateFormatter().string(from: expiresAt) }
        return d
    }
}

/// The grants and the per-agent spend ledger, in `~/.openflix/`.
///
/// Both files are written under an exclusive `flock`, because `openflix agents
/// grant` in a terminal and a running `openflix serve` are two processes that
/// can touch them at once — the same reason `BudgetManager` locks its ledger.
final class AgentGrantStore: @unchecked Sendable {

    static let shared = AgentGrantStore()

    private let directory: URL
    private var grantsURL: URL { directory.appendingPathComponent("agents.json") }
    private var ledgerURL: URL { directory.appendingPathComponent("agent_spend.json") }
    private var lockURL: URL { directory.appendingPathComponent("agents.lock") }

    /// Injectable so tests never touch the real `~/.openflix`.
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openflix", isDirectory: true)
    }

    // MARK: Tokens

    /// `ofx_` + 32 random bytes, base64url. The prefix makes a leaked token
    /// recognisable to secret scanners and to a person reading a log.
    static func newToken() -> String {
        let key = SymmetricKey(size: .bits256)
        let bytes = key.withUnsafeBytes { Data($0) }
        let encoded = bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "ofx_" + encoded
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Compares every byte whatever the input, so the time taken does not say
    /// how much of a guessed hash was right.
    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for i in x.indices { difference |= x[i] ^ y[i] }
        return difference == 0
    }

    // MARK: Grants

    func all() -> [AgentGrant] {
        withLock { loadGrants() }
    }

    /// Creates or replaces the grant called `name` and returns it with the
    /// token — the only time the token exists outside the agent's own store.
    func grant(name: String, effects: [ActionEffect], dailyCapUSD: Double,
               expiresAt: Date? = nil, now: Date = Date()) throws -> (grant: AgentGrant, token: String) {
        guard MCPIdentifier.isWellFormed(name) else {
            throw OpenFlixError.invalidInput("Agent name must be letters, digits, '.', '_' or '-' (max \(MCPIdentifier.maxLength))")
        }
        guard dailyCapUSD.isFinite, dailyCapUSD >= 0 else {
            throw OpenFlixError.invalidInput("--daily-cap must be a finite, non-negative number of US dollars")
        }
        if effects.contains(.spend) && dailyCapUSD <= 0 {
            throw OpenFlixError.invalidInput("A grant that may spend needs --daily-cap above 0: the cap is what bounds an agent's spending")
        }
        let token = Self.newToken()
        let grant = AgentGrant(name: name, tokenHash: Self.hash(token),
                               effects: Array(Set(effects)).sorted { $0.rawValue < $1.rawValue },
                               dailyCapUSD: dailyCapUSD, createdAt: now, expiresAt: expiresAt)
        try withLock {
            var grants = loadGrants().filter { $0.name != name }
            grants.append(grant)
            try saveGrants(grants)
        }
        return (grant, token)
    }

    @discardableResult
    func revoke(name: String) throws -> Bool {
        try withLock {
            let grants = loadGrants()
            let kept = grants.filter { $0.name != name }
            guard kept.count != grants.count else { return false }
            try saveGrants(kept)
            return true
        }
    }

    /// The live grant a bearer token belongs to, or nil. Checks every grant
    /// rather than stopping at the first match.
    func authenticate(token: String, now: Date = Date()) -> AgentGrant? {
        let presented = Self.hash(token)
        var match: AgentGrant?
        for grant in all() where Self.constantTimeEqual(grant.tokenHash, presented) {
            match = grant
        }
        guard let match, !match.isExpired(at: now) else { return nil }
        return match
    }

    // MARK: Spend ledger

    func spentToday(_ name: String, now: Date = Date()) -> Double {
        withLock { loadLedger()[Self.day(now)]?[name] ?? 0 }
    }

    /// Adds to today's total for `name` and returns the new total. Only
    /// finite, positive amounts are recorded.
    @discardableResult
    func recordSpend(_ name: String, amountUSD: Double, now: Date = Date()) throws -> Double {
        guard amountUSD.isFinite, amountUSD > 0 else { return spentToday(name, now: now) }
        return try withLock {
            var ledger = loadLedger()
            let day = Self.day(now)
            var today = ledger[day] ?? [:]
            today[name, default: 0] += amountUSD
            ledger[day] = today
            // Keep a month of history; the ledger only ever needs today.
            let recent = ledger.keys.sorted().suffix(31)
            ledger = ledger.filter { recent.contains($0.key) }
            try write(ledger, to: ledgerURL)
            return today[name] ?? 0
        }
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // MARK: Files

    private let processLock = NSLock()

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        processLock.lock()
        defer { processLock.unlock() }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return try body() }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN); close(fd) }
        return try body()
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func loadGrants() -> [AgentGrant] {
        guard let data = try? Data(contentsOf: grantsURL),
              let grants = try? Self.decoder.decode([AgentGrant].self, from: data) else { return [] }
        return grants
    }

    private func saveGrants(_ grants: [AgentGrant]) throws {
        try write(grants.sorted { $0.name < $1.name }, to: grantsURL)
    }

    private func loadLedger() -> [String: [String: Double]] {
        guard let data = try? Data(contentsOf: ledgerURL),
              let ledger = try? JSONDecoder().decode([String: [String: Double]].self, from: data) else { return [:] }
        return ledger
    }

    /// Atomic write, then `0600`: these files decide who may spend.
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
