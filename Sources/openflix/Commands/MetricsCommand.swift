import ArgumentParser
import Foundation

struct Metrics: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "metrics",
        abstract: "Show provider quality and performance metrics",
        discussion: """
        Displays aggregated metrics for provider/model combinations
        including quality scores, latency, cost, and success rates.

        EXAMPLES
          openflix metrics
          openflix metrics --provider fal
          openflix metrics --sort latency --pretty
        """
    )

    @Option(name: .long, help: "Filter by provider")
    var provider: String?

    @Option(name: .long, help: "Sort by: quality, latency, cost, success_rate (default: quality)")
    var sort: String?

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        var metrics = ProviderMetricsStore.shared.allMetrics()

        // Filter by provider
        if let p = provider {
            metrics = metrics.filter { $0.provider == p }
        }

        // Sort
        let sortKey = sort ?? "quality"
        switch sortKey {
        case "quality":
            metrics.sort { $0.avgQuality > $1.avgQuality }
        case "latency":
            metrics.sort { $0.avgLatencyMs < $1.avgLatencyMs }
        case "cost":
            metrics.sort { $0.avgCostUSD < $1.avgCostUSD }
        case "success_rate":
            metrics.sort { $0.successRate > $1.successRate }
        default:
            Output.failMessage("Unknown sort key '\(sortKey)'. Use: quality, latency, cost, success_rate", code: "invalid_input")
        }

        let output = metrics.map { $0.jsonRepresentation }
        Output.emitArray(output)
    }
}
