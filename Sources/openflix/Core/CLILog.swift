import Foundation
import OSLog
import CryptoKit

// MARK: - Log level

/// Verbosity for the operational log. `off` disables every sink.
enum CLILogLevel: String, Comparable, CaseIterable {
    case debug, info, warn, error, off

    private var rank: Int {
        switch self {
        case .debug: return 0
        case .info:  return 1
        case .warn:  return 2
        case .error: return 3
        case .off:   return 4
        }
    }

    static func < (lhs: CLILogLevel, rhs: CLILogLevel) -> Bool { lhs.rank < rhs.rank }

    /// Lenient parse: unknown / empty strings fall back to `default`.
    /// Accepts common aliases so `OPENFLIX_LOG_LEVEL=warning` or `=none` work.
    static func parse(_ raw: String?, default fallback: CLILogLevel = .info) -> CLILogLevel {
        guard let raw else { return fallback }
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "debug", "verbose", "trace": return .debug
        case "info", "":                  return raw.isEmpty ? fallback : .info
        case "warn", "warning":           return .warn
        case "error", "err":              return .error
        case "off", "none", "silent", "0": return .off
        default:                          return fallback
        }
    }
}

// MARK: - Redaction

/// Scrubbing applied to *everything* before it reaches a log sink.
///
/// API keys live in the keychain precisely so they never land in a file, and a
/// prompt is user content we have no business persisting a second time. These
/// are pure functions so the redaction itself is unit-tested — an unverified
/// redactor is worse than no logging, because it invites logging secrets.
enum CLIRedact {

    static let placeholder = "[redacted]"

    /// `URLComponents.percentEncodedQuery` *traps* if handed characters that
    /// are illegal in a query — including the brackets in `placeholder`. The
    /// query marker therefore has to be plain.
    static let queryPlaceholder = "redacted"

    /// Field names whose *value* is always replaced, whatever it looks like.
    private static let sensitiveKeys: Set<String> = [
        "apikey", "api_key", "key", "token", "accesstoken", "access_token",
        "authorization", "auth", "bearer", "secret", "password", "passwd",
        "credential", "credentials", "session", "cookie", "signature", "sig",
    ]

    static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
        if sensitiveKeys.contains(normalized) { return true }
        if sensitiveKeys.contains(normalized.replacingOccurrences(of: "_", with: "")) { return true }
        return normalized.hasSuffix("_key") || normalized.hasSuffix("_token")
            || normalized.hasSuffix("_secret") || normalized.hasSuffix("_password")
    }

    /// Patterns that look like a credential wherever they appear in free text
    /// (provider error bodies routinely echo the request headers back).
    private static let secretPatterns: [String] = [
        // Authorization headers, with or without a scheme.
        #"(?i)\bbearer\s+[A-Za-z0-9._\-~+/=]{8,}"#,
        #"(?i)\bauthorization\s*[:=]\s*\S+"#,
        #"(?i)\b(?:x-)?api[-_]?key\s*[:=]\s*\S+"#,
        // Vendor-shaped keys: OpenAI/Anthropic sk-, Replicate r8_, generic key-.
        #"\bsk-[A-Za-z0-9_\-]{8,}"#,
        #"\br8_[A-Za-z0-9]{8,}"#,
        #"\bkey-[A-Za-z0-9]{8,}"#,
        // fal.ai style "<uuid>:<hex>".
        #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}:[0-9a-fA-F]{16,}"#,
        // JSON-ish "token": "…" / "secret": "…" pairs.
        #"(?i)"(?:api_?key|access_?token|token|secret|password)"\s*:\s*"[^"]*""#,
    ]

    private static let compiled: [NSRegularExpression] = secretPatterns.compactMap {
        try? NSRegularExpression(pattern: $0)
    }

    /// Scrub credential-shaped substrings out of free text.
    static func text(_ input: String) -> String {
        var out = input
        for regex in compiled {
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: placeholder)
        }
        return out
    }

    /// A URL is safe to log without its query string and userinfo — signed
    /// asset URLs carry the credential in the query.
    static func url(_ url: URL?) -> String? {
        guard let url else { return nil }
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return text(url.absoluteString)
        }
        let hadQuery = !(comps.percentEncodedQuery ?? "").isEmpty
        comps.percentEncodedQuery = hadQuery ? queryPlaceholder : nil
        comps.user = nil
        comps.password = nil
        comps.fragment = nil
        return comps.string.map(text) ?? text(url.absoluteString)
    }

    /// Prompts are never logged verbatim by default. The digest is enough to
    /// answer "was this the same prompt as the run that worked?" without
    /// keeping a second copy of user content next to the generation store.
    static func promptFields(_ prompt: String, includePreview: Bool = false) -> [String: Any] {
        let digest = SHA256.hash(data: Data(prompt.utf8))
            .map { String(format: "%02x", $0) }.joined()
        var fields: [String: Any] = [
            "prompt_sha256": String(digest.prefix(12)),
            "prompt_chars": prompt.count,
        ]
        if includePreview {
            let preview = prompt.prefix(64)
            fields["prompt_preview"] = text(String(preview)) + (prompt.count > 64 ? "…" : "")
        }
        return fields
    }

    /// Recursively scrub a field dictionary: sensitive keys lose their value,
    /// every string is run through the free-text scrubber.
    static func fields(_ input: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in input {
            if isSensitiveKey(key) {
                out[key] = placeholder
            } else {
                out[key] = scrub(value)
            }
        }
        return out
    }

    private static func scrub(_ value: Any) -> Any {
        switch value {
        case Optional<Any>.none:         return NSNull()
        case is NSNull:                  return NSNull()
        case let s as String:            return text(s)
        case let u as URL:               return url(u) ?? placeholder
        case let d as [String: Any]:     return fields(d)
        case let a as [Any]:             return a.map(scrub)
        case let b as Bool:              return b
        case let i as Int:               return i
        // Non-finite doubles must be caught BEFORE the NSNumber bridge:
        // JSONSerialization refuses NaN/±inf and would drop the whole entry.
        case let d as Double:            return d.isFinite ? d : String(describing: d)
        case let n as NSNumber:          return n.doubleValue.isFinite ? n : String(describing: n)
        case let date as Date:           return ISO8601DateFormatter().string(from: date)
        default:                         return text(String(describing: value))
        }
    }
}

// MARK: - Logger

/// The CLI's operational log.
///
/// **Design constraints, in priority order:**
///
/// 1. **stdout is the CLI's API.** `workflow run --json`, the streaming event
///    feed and every command's result JSON are parsed by scripts and by the Mac
///    app. Nothing here ever writes to stdout — sinks are `OSLog`, a JSONL file
///    under `~/.openflix/logs/`, and (opt-in) stderr.
/// 2. **Never log a credential or a full prompt.** Everything passes through
///    `CLIRedact` first; prompts are recorded as a digest.
/// 3. **Never break the CLI.** Every sink failure is swallowed. A tool that
///    can't spend money because its log directory is read-only is a worse tool.
///
/// **Configuration** (env only — the CLI has no global verbosity flag, and
/// adding one to 30 subcommands would be worse than an env var for a tool that
/// mostly runs unattended):
///
/// - `OPENFLIX_LOG_LEVEL` — `debug|info|warn|error|off` (default `info`)
/// - `OPENFLIX_LOG_FILE`  — override the JSONL path; `none` disables the file
/// - `OPENFLIX_LOG_STDERR` — `1` to mirror lines to stderr
///
/// The run journal (`RunJournal`, `~/.openflix/runs/<id>.json`) is the *state*
/// of a DAG run and is resumable; this is the *narrative* of what the process
/// did. They sit beside each other deliberately — the journal must stay a
/// clean, machine-owned document.
final class CLILog {

    /// Process-wide logger. Tests build their own instance with an injected
    /// directory rather than touching this one.
    static let shared: CLILog = {
        let env = ProcessInfo.processInfo.environment
        // Under XCTest, default to silent: a unit-test run must not append to
        // the developer's real ~/.openflix/logs. An explicit level still wins.
        let underTest = env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
        let level = CLILogLevel.parse(env["OPENFLIX_LOG_LEVEL"],
                                      default: underTest ? .off : .info)
        return CLILog(
            level: level,
            fileURL: resolveFileURL(env["OPENFLIX_LOG_FILE"], enabled: !underTest),
            mirrorToStderr: env["OPENFLIX_LOG_STDERR"].map { $0 == "1" || $0.lowercased() == "true" } ?? false
        )
    }()

    /// Rotate once the file passes this size, keeping exactly one previous log.
    static let defaultMaxFileBytes: Int = 1_048_576

    let level: CLILogLevel
    let fileURL: URL?
    let mirrorToStderr: Bool
    let maxFileBytes: Int

    private let lock = NSLock()
    private let osLogger = Logger(subsystem: "com.openflix.cli", category: "cli")

    init(level: CLILogLevel = .info, fileURL: URL?, mirrorToStderr: Bool = false,
         maxFileBytes: Int = CLILog.defaultMaxFileBytes) {
        self.level = level
        self.fileURL = fileURL
        self.mirrorToStderr = mirrorToStderr
        self.maxFileBytes = maxFileBytes
    }

    /// Convenience for tests: log into a directory instead of a file path.
    convenience init(directory: URL, level: CLILogLevel = .debug, mirrorToStderr: Bool = false,
                     maxFileBytes: Int = CLILog.defaultMaxFileBytes) {
        self.init(level: level,
                  fileURL: directory.appendingPathComponent("openflix.log"),
                  mirrorToStderr: mirrorToStderr,
                  maxFileBytes: maxFileBytes)
    }

    private static func resolveFileURL(_ override: String?, enabled: Bool) -> URL? {
        if let override {
            let trimmed = override.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.lowercased() == "none" || trimmed.lowercased() == "off" {
                return nil
            }
            return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        }
        guard enabled else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openflix/logs/openflix.log")
    }

    // MARK: - Emit

    /// Build the record for `event` without writing it (exposed for tests).
    func record(_ level: CLILogLevel, _ event: String, _ fields: [String: Any]) -> [String: Any] {
        [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "level": level.rawValue,
            "event": event,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "fields": CLIRedact.fields(fields),
        ]
    }

    func log(_ level: CLILogLevel, _ event: String, _ fields: [String: Any] = [:]) {
        guard self.level != .off, level >= self.level, level != .off else { return }
        var entry = record(level, event, fields)
        // An un-serialisable field must never cost us the whole record — the
        // event name is the part someone needs at 3 a.m.
        if !JSONSerialization.isValidJSONObject(entry) {
            entry["fields"] = ["serialization": "dropped (non-JSON field)"]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes]),
              let line = String(data: data, encoding: .utf8) else { return }

        // Fields are already redacted, so the unified log can hold them public.
        switch level {
        case .debug: osLogger.debug("\(line, privacy: .public)")
        case .info:  osLogger.info("\(line, privacy: .public)")
        case .warn:  osLogger.warning("\(line, privacy: .public)")
        case .error: osLogger.error("\(line, privacy: .public)")
        case .off:   break
        }

        if mirrorToStderr { fputs(line + "\n", stderr) }
        appendToFile(line)
    }

    func debug(_ event: String, _ fields: [String: Any] = [:]) { log(.debug, event, fields) }
    func info(_ event: String, _ fields: [String: Any] = [:])  { log(.info, event, fields) }
    func warn(_ event: String, _ fields: [String: Any] = [:])  { log(.warn, event, fields) }
    func error(_ event: String, _ fields: [String: Any] = [:]) { log(.error, event, fields) }

    // MARK: - File sink

    private func appendToFile(_ line: String) {
        guard let fileURL else { return }
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        rotateIfNeededLocked(fileURL, fm: fm)

        guard let data = (line + "\n").data(using: .utf8) else { return }
        if !fm.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    /// Keep the log bounded: one rollover file, no unbounded growth on a
    /// machine that runs `project run` nightly.
    private func rotateIfNeededLocked(_ url: URL, fm: FileManager) {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber,
              size.intValue >= maxFileBytes else { return }
        let rolled = url.appendingPathExtension("1")
        try? fm.removeItem(at: rolled)
        try? fm.moveItem(at: url, to: rolled)
    }

    // MARK: - Static conveniences (call sites stay one line)

    static func debug(_ event: String, _ fields: [String: Any] = [:]) { shared.debug(event, fields) }
    static func info(_ event: String, _ fields: [String: Any] = [:])  { shared.info(event, fields) }
    static func warn(_ event: String, _ fields: [String: Any] = [:])  { shared.warn(event, fields) }
    static func error(_ event: String, _ fields: [String: Any] = [:]) { shared.error(event, fields) }
}
