import Foundation
import OpenFlixKit

// MARK: - Preference summary (registry contract)

/// Aggregate preference data from GET {registry}/api/preferences/summary.
/// Only the fields the router needs are decoded; unknown keys (e.g. "pairs")
/// are ignored.
struct PreferenceSummary: Codable {
    struct CategoryStats: Codable {
        let wins: Int
        let losses: Int

        var events: Int { wins + losses }

        /// Laplace-smoothed win rate: (wins + 1) / (events + 2).
        var laplaceWinRate: Double {
            Double(wins + 1) / Double(events + 2)
        }
    }

    struct ModelStats: Codable {
        let model: String
        let provider: String
        let wins: Int
        let losses: Int
        let winRate: Double
        let categories: [String: CategoryStats]?

        enum CodingKeys: String, CodingKey {
            case model, provider, wins, losses, categories
            case winRate = "win_rate"
        }
    }

    let models: [ModelStats]
    let totalEvents: Int?
    let generatedAt: String?

    enum CodingKeys: String, CodingKey {
        case models
        case totalEvents = "total_events"
        case generatedAt = "generated_at"
    }
}

// MARK: - Cache (24h TTL, ~/.openflix/preference_summary.json)

/// File cache for the preference summary. TTL is checked against file mtime.
/// Directory is injectable for tests; defaults to ~/.openflix.
struct PreferenceSummaryCache {
    let cacheURL: URL
    let ttl: TimeInterval

    init(directory: URL? = nil, ttl: TimeInterval = 24 * 60 * 60) {
        let base = directory
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openflix")
        cacheURL = base.appendingPathComponent("preference_summary.json")
        self.ttl = ttl
    }

    /// True when the cache file exists and its mtime is within the TTL.
    func isFresh(now: Date = Date()) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
              let mtime = attrs[.modificationDate] as? Date else { return false }
        return now.timeIntervalSince(mtime) < ttl
    }

    /// Load and decode the cached summary regardless of age.
    func load() -> PreferenceSummary? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(PreferenceSummary.self, from: data)
    }

    func save(_ data: Data) {
        let dir = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}

// MARK: - Preference-aware ("smart") routing

enum PreferenceRouter {

    /// Minimum category events before category-level stats override the
    /// overall win rate.
    static let minCategoryEvents = 5

    struct SmartChoice {
        let provider: String
        let model: String
        let winRate: Double
        let categoryEvents: Int
        let usedCategoryStats: Bool
    }

    /// Pure selection: among candidates, pick the highest Laplace-smoothed
    /// win rate for `category`, falling back to the overall win rate when
    /// the category has fewer than `minCategoryEvents` events. Candidates
    /// absent from the summary are skipped; returns nil when none match.
    static func select(
        candidates: [(provider: String, model: String)],
        summary: PreferenceSummary,
        category: String?
    ) -> SmartChoice? {
        var best: SmartChoice?
        for candidate in candidates {
            guard let stats = summary.models.first(where: {
                $0.provider == candidate.provider && $0.model == candidate.model
            }) else { continue }

            var rate = stats.winRate
            var categoryEvents = 0
            var usedCategory = false
            if let cat = category, let cs = stats.categories?[cat] {
                categoryEvents = cs.events
                if categoryEvents >= minCategoryEvents {
                    rate = cs.laplaceWinRate
                    usedCategory = true
                }
            }

            if best == nil || rate > best!.winRate {
                best = SmartChoice(
                    provider: candidate.provider, model: candidate.model,
                    winRate: rate, categoryEvents: categoryEvents,
                    usedCategoryStats: usedCategory
                )
            }
        }
        return best
    }

    // MARK: Summary loading (network -> fresh cache -> stale cache)

    enum SummarySource: String {
        case network
        case cache
        case staleCache = "stale_cache"
        case none
    }

    /// Load the preference summary without ever throwing: fresh cache first,
    /// then network (caching the result), then stale cache as a last resort.
    static func loadSummary(cache: PreferenceSummaryCache = PreferenceSummaryCache()) async -> (summary: PreferenceSummary?, source: SummarySource) {
        if cache.isFresh(), let cached = cache.load() {
            return (cached, .cache)
        }
        do {
            let data = try await RegistryClient.fetchPreferenceSummaryData()
            let summary = try JSONDecoder().decode(PreferenceSummary.self, from: data)
            cache.save(data)
            return (summary, .network)
        } catch {
            // Offline / registry down: any cache beats no data.
            if let stale = cache.load() {
                return (stale, .staleCache)
            }
            return (nil, .none)
        }
    }

    // MARK: Full decision for the generate command

    struct Decision {
        let provider: String
        let model: String
        let json: [String: Any]
    }

    /// Smart-routing flow: candidates = models the user has keys for that fit
    /// the request; pick by preference win rate; fall back to cheapest with a
    /// stderr warning when preference data is unavailable. Never fails
    /// because the registry is down.
    static func decide(
        category: String?,
        needsImageToVideo: Bool,
        duration: Double?,
        cache: PreferenceSummaryCache = PreferenceSummaryCache()
    ) async throws -> Decision {
        let available = ProviderRouter.availableProviders()
        guard !available.isEmpty else {
            throw OpenFlixError.invalidResponse("Smart routing requires at least one configured provider key. Run: openflix keys set <provider> <key>")
        }

        var candidates = ProviderRegistry.shared.allModels.filter { available.contains($0.providerId) }
        if needsImageToVideo {
            candidates = candidates.filter { $0.supportsImageToVideo }
        }
        if let d = duration {
            candidates = candidates.filter { m in
                guard let max = m.maxDurationSeconds else { return true }
                return max >= d
            }
        }
        guard !candidates.isEmpty else {
            throw OpenFlixError.invalidResponse("No provider/model matches request requirements (available: \(available.joined(separator: ", ")))")
        }

        let (summary, source) = await loadSummary(cache: cache)
        if source == .staleCache {
            warn("Registry unreachable; using stale preference cache for smart routing.", code: "registry_unavailable")
        }

        if let summary,
           let choice = select(
               candidates: candidates.map { ($0.providerId, $0.modelId) },
               summary: summary,
               category: category
           ) {
            var json: [String: Any] = [
                "mode": "smart",
                "chosen": "\(choice.provider)/\(choice.model)",
                "win_rate": (choice.winRate * 10000).rounded() / 10000,
                "category_events": choice.categoryEvents,
                "used_category_stats": choice.usedCategoryStats,
                "fallback": false,
                "source": source.rawValue,
            ]
            if let category { json["category"] = category }
            return Decision(provider: choice.provider, model: choice.model, json: json)
        }

        // Fallback: no preference data (or no candidate appears in it) —
        // use the existing default heuristic (cheapest capable model).
        let reason = summary == nil
            ? "preference data unavailable (registry unreachable, no cache)"
            : "no configured provider/model appears in preference data"
        warn("Smart routing fell back to default (cheapest) routing: \(reason).", code: "smart_routing_fallback")

        let best = candidates.sorted {
            ($0.costPerSecondUSD ?? .infinity) < ($1.costPerSecondUSD ?? .infinity)
        }[0]
        var json: [String: Any] = [
            "mode": "smart",
            "chosen": "\(best.providerId)/\(best.modelId)",
            "fallback": true,
            "fallback_reason": reason,
            "source": source.rawValue,
        ]
        if let category { json["category"] = category }
        return Decision(provider: best.providerId, model: best.modelId, json: json)
    }

    /// Machine-readable warning on stderr (stdout stays pure JSON payload).
    private static func warn(_ message: String, code: String) {
        let dict: [String: Any] = ["warning": message, "code": code]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            fputs(str + "\n", stderr)
        }
    }
}
