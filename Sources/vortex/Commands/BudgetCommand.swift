import ArgumentParser
import Foundation

struct Budget: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "budget",
        abstract: "Manage daily/per-generation cost limits",
        subcommands: [BudgetStatus.self, BudgetSet.self, BudgetReset.self],
        defaultSubcommand: BudgetStatus.self
    )
}

struct BudgetStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show current spend and budget limits"
    )

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty = false

    func run() async throws {
        Output.pretty = pretty
        let summary = await BudgetManager.shared.statusSummary()
        Output.emitDict(summary)
    }
}

struct BudgetSet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set budget limits"
    )

    @Option(name: .long, help: "Daily spend limit in USD")
    var dailyLimit: Double?

    @Option(name: .long, help: "Max cost per generation in USD")
    var perGenerationMax: Double?

    @Option(name: .long, help: "Monthly spend limit in USD")
    var monthlyLimit: Double?

    @Option(name: .long, help: "Warning threshold percentage (0-100)")
    var warningThreshold: Double?

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty = false

    func run() async throws {
        Output.pretty = pretty

        var config = await BudgetManager.shared.loadConfig()
        if let v = dailyLimit { config.dailyLimitUSD = v }
        if let v = perGenerationMax { config.perGenerationMaxUSD = v }
        if let v = monthlyLimit { config.monthlyLimitUSD = v }
        if let v = warningThreshold {
            guard v > 0 && v <= 100 else {
                Output.failMessage("Warning threshold must be between 0 and 100", code: "input_invalid")
            }
            config.warningThresholdPercent = v
        }

        try await BudgetManager.shared.saveConfig(config)
        Output.emitDict(["status": "ok", "message": "Budget limits updated"])
    }
}

struct BudgetReset: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reset",
        abstract: "Reset daily spend counter"
    )

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty = false

    func run() async throws {
        Output.pretty = pretty
        try await BudgetManager.shared.resetDailySpend()
        Output.emitDict(["status": "ok", "message": "Daily spend reset"])
    }
}
