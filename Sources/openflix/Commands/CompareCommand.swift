import ArgumentParser
import Foundation

struct Compare: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compare",
        abstract: "Compare two generations side by side",
        discussion: """
        Evaluates and compares two generations, showing quality scores
        and cost/latency differences.

        EXAMPLES
          openflix compare <gen-id-1> <gen-id-2>
        """
    )

    @Argument(help: "First generation ID")
    var generationA: String

    @Argument(help: "Second generation ID")
    var generationB: String

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        // 1. Fetch both generations
        guard let genA = GenerationStore.shared.get(generationA) else {
            Output.failMessage("Generation '\(generationA)' not found", code: "not_found")
        }
        guard let genB = GenerationStore.shared.get(generationB) else {
            Output.failMessage("Generation '\(generationB)' not found", code: "not_found")
        }

        // 2. Build comparison entries
        let entryA = try await buildEntry(gen: genA)
        let entryB = try await buildEntry(gen: genB)

        // 3. Determine winner
        let winner: [String: Any]
        let scoreA = entryA["quality_score"] as? Double
        let scoreB = entryB["quality_score"] as? Double
        let statusA = genA.status == .succeeded
        let statusB = genB.status == .succeeded

        if statusA && !statusB {
            winner = [
                "generation_id": genA.id,
                "provider": genA.provider,
                "reason": "Only succeeded generation",
            ]
        } else if !statusA && statusB {
            winner = [
                "generation_id": genB.id,
                "provider": genB.provider,
                "reason": "Only succeeded generation",
            ]
        } else if let sa = scoreA, let sb = scoreB, sa != sb {
            let best = sa > sb ? genA : genB
            let bestScore = max(sa, sb)
            let worstScore = min(sa, sb)
            winner = [
                "generation_id": best.id,
                "provider": best.provider,
                "reason": "Higher quality (\(bestScore) vs \(worstScore))",
            ]
        } else if let costA = genA.actualCostUSD ?? genA.estimatedCostUSD,
                  let costB = genB.actualCostUSD ?? genB.estimatedCostUSD, costA != costB {
            let best = costA < costB ? genA : genB
            winner = [
                "generation_id": best.id,
                "provider": best.provider,
                "reason": "Lower cost ($\((min(costA, costB) * 10000).rounded() / 10000) vs $\((max(costA, costB) * 10000).rounded() / 10000))",
            ]
        } else {
            winner = [
                "generation_id": genA.id,
                "provider": genA.provider,
                "reason": "Tie (no distinguishing factors)",
            ]
        }

        // 4. Output
        Output.emitDict([
            "comparison": [entryA, entryB],
            "winner": winner,
        ])
    }

    private func buildEntry(gen: CLIGeneration) async throws -> [String: Any] {
        var entry: [String: Any] = [
            "generation_id": gen.id,
            "provider": gen.provider,
            "model": gen.model,
            "status": gen.status.rawValue,
        ]

        if let dur = gen.durationSeconds {
            entry["duration_seconds"] = dur
        }
        if let cost = gen.actualCostUSD ?? gen.estimatedCostUSD {
            entry["cost_usd"] = (cost * 10000).rounded() / 10000
        }

        // Compute latency from submittedAt to completedAt
        if let sub = gen.submittedAt, let comp = gen.completedAt {
            let latency = comp.timeIntervalSince(sub)
            entry["latency_seconds"] = (latency * 10).rounded() / 10
        }

        // Run heuristic evaluation if video exists and generation succeeded
        if gen.status == .succeeded, let localPath = gen.localPath,
           FileManager.default.fileExists(atPath: localPath) {
            var config = QualityConfig()
            config.enabled = true
            config.evaluator = .heuristic
            if let evalResult = try? await QualityGate.evaluate(
                generation: gen, videoPath: localPath, shot: nil, config: config
            ) {
                entry["quality_score"] = (evalResult.score * 10).rounded() / 10
            }
        }

        return entry
    }
}
