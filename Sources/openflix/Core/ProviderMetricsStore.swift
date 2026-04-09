import Foundation
import Darwin

/// Tracks provider+model quality metrics over time.
/// Stored at ~/.openflix/metrics.json with file locking.
final class ProviderMetricsStore {
    static let shared = ProviderMetricsStore()

    private let storeURL: URL
    private let lockFileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".openflix", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("metrics.json")
        lockFileURL = dir.appendingPathComponent("metrics.lock")
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - File lock

    private func withFileLock<T>(_ body: () throws -> T) rethrows -> T {
        let fd = open(lockFileURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return try body() }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN); close(fd) }
        return try body()
    }

    // MARK: - Record

    func recordGeneration(provider: String, model: String, succeeded: Bool, latencyMs: Int, costUSD: Double?) {
        withFileLock {
            lock.lock(); defer { lock.unlock() }
            var all = loadAll()
            let key = "\(provider)/\(model)"
            var m = all[key] ?? ProviderModelMetrics(provider: provider, model: model)
            m.totalGenerations += 1
            if succeeded {
                m.succeededGenerations += 1
            } else {
                m.failedGenerations += 1
            }
            m.totalLatencyMs += latencyMs
            if let cost = costUSD {
                m.totalCostUSD += cost
            }
            m.lastUpdated = Date()
            all[key] = m
            persist(all)
        }
    }

    func recordQuality(provider: String, model: String, score: Double) {
        withFileLock {
            lock.lock(); defer { lock.unlock() }
            var all = loadAll()
            let key = "\(provider)/\(model)"
            var m = all[key] ?? ProviderModelMetrics(provider: provider, model: model)
            m.qualityScores.append(score)
            // Keep last 100 scores
            if m.qualityScores.count > 100 {
                m.qualityScores = Array(m.qualityScores.suffix(100))
            }
            m.lastUpdated = Date()
            all[key] = m
            persist(all)
        }
    }

    func recordFeedback(provider: String, model: String, score: Double) {
        withFileLock {
            lock.lock(); defer { lock.unlock() }
            var all = loadAll()
            let key = "\(provider)/\(model)"
            var m = all[key] ?? ProviderModelMetrics(provider: provider, model: model)
            m.feedbackScores.append(score)
            if m.feedbackScores.count > 100 {
                m.feedbackScores = Array(m.feedbackScores.suffix(100))
            }
            m.lastUpdated = Date()
            all[key] = m
            persist(all)
        }
    }

    // MARK: - Query

    func getMetrics(provider: String, model: String) -> ProviderModelMetrics? {
        withFileLock {
            lock.lock(); defer { lock.unlock() }
            return loadAll()["\(provider)/\(model)"]
        }
    }

    func allMetrics() -> [ProviderModelMetrics] {
        withFileLock {
            lock.lock(); defer { lock.unlock() }
            return Array(loadAll().values).sorted { $0.avgQuality > $1.avgQuality }
        }
    }

    func rankedByQuality() -> [ProviderModelMetrics] {
        allMetrics().filter { !$0.qualityScores.isEmpty }.sorted { $0.avgQuality > $1.avgQuality }
    }

    // MARK: - Private

    private func loadAll() -> [String: ProviderModelMetrics] {
        guard FileManager.default.fileExists(atPath: storeURL.path),
              let data = try? Data(contentsOf: storeURL),
              let map = try? decoder.decode([String: ProviderModelMetrics].self, from: data) else {
            return [:]
        }
        return map
    }

    private func persist(_ map: [String: ProviderModelMetrics]) {
        let data: Data
        do { data = try encoder.encode(map) }
        catch {
            fputs("{\"error\":\"Metrics encode failed: \(error.localizedDescription)\",\"code\":\"store_error\"}\n", stderr)
            return
        }
        do { try data.write(to: storeURL, options: .atomic) }
        catch {
            fputs("{\"error\":\"Metrics write failed: \(error.localizedDescription)\",\"code\":\"store_error\"}\n", stderr)
        }
    }
}

// MARK: - Metrics Model

struct ProviderModelMetrics: Codable {
    var provider: String
    var model: String
    var totalGenerations: Int = 0
    var succeededGenerations: Int = 0
    var failedGenerations: Int = 0
    var totalLatencyMs: Int = 0
    var totalCostUSD: Double = 0
    var qualityScores: [Double] = []
    var feedbackScores: [Double] = []
    var lastUpdated: Date = Date()

    var avgQuality: Double {
        let all = qualityScores + feedbackScores
        guard !all.isEmpty else { return 0 }
        return all.reduce(0, +) / Double(all.count)
    }

    var avgLatencyMs: Double {
        guard totalGenerations > 0 else { return 0 }
        return Double(totalLatencyMs) / Double(totalGenerations)
    }

    var avgCostUSD: Double {
        guard totalGenerations > 0 else { return 0 }
        return totalCostUSD / Double(totalGenerations)
    }

    var successRate: Double {
        guard totalGenerations > 0 else { return 0 }
        return Double(succeededGenerations) / Double(totalGenerations) * 100
    }

    var jsonRepresentation: [String: Any] {
        [
            "provider": provider,
            "model": model,
            "total_generations": totalGenerations,
            "succeeded_generations": succeededGenerations,
            "failed_generations": failedGenerations,
            "avg_quality": round2(avgQuality),
            "avg_latency_ms": round2(avgLatencyMs),
            "avg_cost_usd": round4(avgCostUSD),
            "total_cost_usd": round4(totalCostUSD),
            "success_rate": round2(successRate),
            "quality_samples": qualityScores.count,
            "feedback_samples": feedbackScores.count,
            "last_updated": ISO8601DateFormatter().string(from: lastUpdated),
        ]
    }

    private func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
    private func round4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }
}
