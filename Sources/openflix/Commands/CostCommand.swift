import ArgumentParser
import Foundation

struct Cost: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cost",
        abstract: "Show cost summary for generations",
        discussion: """
        Summarizes actual and estimated costs from local generation history.

        EXAMPLES
          vortex cost
          vortex cost --provider fal
          vortex cost --since 2024-01-01
        """
    )

    @Option(name: .long, help: "Filter by provider ID")
    var provider: String?

    @Option(name: .long, help: "Only include generations created after this date (ISO 8601: YYYY-MM-DD)")
    var since: String?

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        var gens = GenerationStore.shared.all()

        if let p = provider {
            gens = gens.filter { $0.provider == p }
        }

        if let sinceStr = since {
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withFullDate]
            if let sinceDate = fmt.date(from: sinceStr) {
                gens = gens.filter { $0.createdAt >= sinceDate }
            }
        }

        let succeeded = gens.filter { $0.status == .succeeded }
        let totalActual = succeeded.compactMap { $0.actualCostUSD }.reduce(0, +)
        let totalEstimated = gens.compactMap { $0.estimatedCostUSD }.reduce(0, +)

        // Per-provider breakdown
        var byProvider: [String: [String: Any]] = [:]
        for gen in gens {
            var entry = byProvider[gen.provider] ?? [
                "provider": gen.provider,
                "total_count": 0,
                "succeeded_count": 0,
                "actual_cost_usd": 0.0,
                "estimated_cost_usd": 0.0,
            ]
            entry["total_count"] = ((entry["total_count"] as? Int) ?? 0) + 1
            if gen.status == .succeeded {
                entry["succeeded_count"] = ((entry["succeeded_count"] as? Int) ?? 0) + 1
                entry["actual_cost_usd"] = ((entry["actual_cost_usd"] as? Double) ?? 0) + (gen.actualCostUSD ?? 0)
            }
            entry["estimated_cost_usd"] = ((entry["estimated_cost_usd"] as? Double) ?? 0) + (gen.estimatedCostUSD ?? 0)
            byProvider[gen.provider] = entry
        }

        Output.emitDict([
            "total_generations": gens.count,
            "succeeded_generations": succeeded.count,
            "total_actual_cost_usd": totalActual,
            "total_estimated_cost_usd": totalEstimated,
            "by_provider": Array(byProvider.values),
        ])
    }
}
