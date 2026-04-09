import Foundation

/// Manages daily and per-generation cost limits for autonomous agent use.
actor BudgetManager {
    static let shared = BudgetManager()

    struct BudgetConfig: Codable {
        var dailyLimitUSD: Double?
        var perGenerationMaxUSD: Double?
        var monthlyLimitUSD: Double?
        var warningThresholdPercent: Double = 80

        static let empty = BudgetConfig()
    }

    struct DailySpend: Codable {
        var date: String
        var totalUSD: Double
        var generationCount: Int
    }

    private let configURL: URL
    private let spendURL: URL
    private var cachedConfig: BudgetConfig?
    private var cachedSpend: DailySpend?

    private init() {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vortex")
        configURL = base.appendingPathComponent("budget_config.json")
        spendURL = base.appendingPathComponent("daily_spend.json")
    }

    // MARK: - Config

    func loadConfig() -> BudgetConfig {
        if let c = cachedConfig { return c }
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(BudgetConfig.self, from: data) else {
            return .empty
        }
        cachedConfig = config
        return config
    }

    func saveConfig(_ config: BudgetConfig) throws {
        let dir = configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(config)
        try data.write(to: configURL, options: .atomic)
        cachedConfig = config
    }

    // MARK: - Daily spend

    func loadSpend() -> DailySpend {
        if let s = cachedSpend, s.date == todayString() { return s }
        guard let data = try? Data(contentsOf: spendURL),
              let spend = try? JSONDecoder().decode(DailySpend.self, from: data),
              spend.date == todayString() else {
            let fresh = DailySpend(date: todayString(), totalUSD: 0, generationCount: 0)
            cachedSpend = fresh
            return fresh
        }
        cachedSpend = spend
        return spend
    }

    private func saveSpend(_ spend: DailySpend) throws {
        let dir = spendURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(spend)
        try data.write(to: spendURL, options: .atomic)
        cachedSpend = spend
    }

    // MARK: - Pre-flight check

    enum BudgetCheckResult {
        case approved
        case warning(remaining: Double)
        case denied(reason: String)
    }

    func preFlightCheck(estimatedCost: Double) -> BudgetCheckResult {
        let config = loadConfig()
        let spend = loadSpend()

        // Per-generation limit
        if let maxPerGen = config.perGenerationMaxUSD, estimatedCost > maxPerGen {
            return .denied(reason: "Estimated cost $\(String(format: "%.4f", estimatedCost)) exceeds per-generation limit $\(String(format: "%.4f", maxPerGen))")
        }

        // Daily limit
        if let dailyLimit = config.dailyLimitUSD {
            let projected = spend.totalUSD + estimatedCost
            if projected > dailyLimit {
                return .denied(reason: "Daily spend $\(String(format: "%.4f", spend.totalUSD)) + estimated $\(String(format: "%.4f", estimatedCost)) exceeds daily limit $\(String(format: "%.4f", dailyLimit))")
            }
            let threshold = dailyLimit * (config.warningThresholdPercent / 100.0)
            if projected > threshold {
                return .warning(remaining: dailyLimit - spend.totalUSD)
            }
        }

        // Monthly limit
        if let monthlyLimit = config.monthlyLimitUSD {
            let monthlySpend = loadMonthlySpend()
            let projected = monthlySpend + estimatedCost
            if projected > monthlyLimit {
                return .denied(reason: "Monthly spend $\(String(format: "%.4f", monthlySpend)) + estimated $\(String(format: "%.4f", estimatedCost)) exceeds monthly limit $\(String(format: "%.4f", monthlyLimit))")
            }
        }

        return .approved
    }

    // MARK: - Record spend

    func recordSpend(amount: Double) {
        var spend = loadSpend()
        spend.totalUSD += amount
        spend.generationCount += 1
        try? saveSpend(spend)
    }

    func currentSpend() -> DailySpend {
        return loadSpend()
    }

    func remainingBudget() -> Double? {
        let config = loadConfig()
        guard let limit = config.dailyLimitUSD else { return nil }
        let spend = loadSpend()
        return max(0, limit - spend.totalUSD)
    }

    func resetDailySpend() throws {
        let fresh = DailySpend(date: todayString(), totalUSD: 0, generationCount: 0)
        try saveSpend(fresh)
    }

    // MARK: - Monthly spend (sum of daily files is approximated by current daily)

    private func loadMonthlySpend() -> Double {
        // For simplicity, we track monthly via the daily spend file
        // A production system would aggregate across days
        return loadSpend().totalUSD
    }

    // MARK: - Helpers

    private func todayString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone.current
        return fmt.string(from: Date())
    }

    /// Status summary for CLI/MCP output.
    func statusSummary() -> [String: Any] {
        let config = loadConfig()
        let spend = loadSpend()
        var d: [String: Any] = [
            "date": spend.date,
            "daily_spend_usd": (spend.totalUSD * 10000).rounded() / 10000,
            "generation_count": spend.generationCount,
        ]
        if let limit = config.dailyLimitUSD {
            d["daily_limit_usd"] = limit
            d["daily_remaining_usd"] = ((max(0, limit - spend.totalUSD)) * 10000).rounded() / 10000
        }
        if let limit = config.perGenerationMaxUSD {
            d["per_generation_max_usd"] = limit
        }
        if let limit = config.monthlyLimitUSD {
            d["monthly_limit_usd"] = limit
        }
        d["warning_threshold_percent"] = config.warningThresholdPercent
        return d
    }
}
