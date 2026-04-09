import Foundation

struct ProviderRouter {

    struct RoutingDecision: Codable {
        var provider: String
        var model: String
        var reason: String
        var estimatedCostUSD: Double?
    }

    /// Route a shot to the best provider/model based on strategy.
    static func route(
        shot: Shot,
        strategy: ProjectSettings.RoutingStrategy,
        availableProviders: [String]
    ) throws -> RoutingDecision {
        let allModels = ProviderRegistry.shared.allModels

        // Filter to available providers
        var candidates = allModels.filter { availableProviders.contains($0.providerId) }

        // Capability filter: I2V
        if shot.referenceImageURL != nil {
            candidates = candidates.filter { $0.supportsImageToVideo }
        }

        // Capability filter: duration
        if let d = shot.duration {
            candidates = candidates.filter { m in
                guard let max = m.maxDurationSeconds else { return true }
                return max >= d
            }
        }

        guard !candidates.isEmpty else {
            throw OpenFlixError.invalidResponse("No provider/model matches shot requirements (available: \(availableProviders.joined(separator: ", ")))")
        }

        switch strategy {
        case .cheapest:
            let sorted = candidates.sorted {
                ($0.costPerSecondUSD ?? Double.infinity) < ($1.costPerSecondUSD ?? Double.infinity)
            }
            let best = sorted[0]
            let cost = estimateCost(model: best, duration: shot.duration)
            return RoutingDecision(
                provider: best.providerId, model: best.modelId,
                reason: "Cheapest: \(best.displayName) at $\(best.costPerSecondUSD ?? 0)/s",
                estimatedCostUSD: cost
            )

        case .fastest:
            // Heuristic: shorter max duration = faster turnaround
            let sorted = candidates.sorted {
                ($0.maxDurationSeconds ?? Double.infinity) < ($1.maxDurationSeconds ?? Double.infinity)
            }
            let best = sorted[0]
            let cost = estimateCost(model: best, duration: shot.duration)
            return RoutingDecision(
                provider: best.providerId, model: best.modelId,
                reason: "Fastest (heuristic): \(best.displayName)",
                estimatedCostUSD: cost
            )

        case .quality:
            // Use real metrics if available, fall back to cost proxy
            let ranked = ProviderMetricsStore.shared.rankedByQuality()
            if let topMetric = ranked.first(where: { m in
                candidates.contains { $0.providerId == m.provider && $0.modelId == m.model }
            }) {
                let matched = candidates.first { $0.providerId == topMetric.provider && $0.modelId == topMetric.model }!
                let cost = estimateCost(model: matched, duration: shot.duration)
                return RoutingDecision(
                    provider: matched.providerId, model: matched.modelId,
                    reason: "Highest quality (avg \(String(format: "%.1f", topMetric.avgQuality))): \(matched.displayName)",
                    estimatedCostUSD: cost
                )
            }
            // Fallback: cost proxy
            let sorted = candidates.sorted {
                ($0.costPerSecondUSD ?? 0) > ($1.costPerSecondUSD ?? 0)
            }
            let best = sorted[0]
            let cost = estimateCost(model: best, duration: shot.duration)
            return RoutingDecision(
                provider: best.providerId, model: best.modelId,
                reason: "Highest quality (by cost proxy): \(best.displayName)",
                estimatedCostUSD: cost
            )

        case .manual:
            guard let p = shot.provider, let m = shot.model else {
                throw OpenFlixError.invalidResponse("Manual routing requires provider and model on each shot")
            }
            let matched = candidates.first { $0.providerId == p && $0.modelId == m }
            let cost = matched.flatMap { estimateCost(model: $0, duration: shot.duration) }
            return RoutingDecision(provider: p, model: m, reason: "Manual", estimatedCostUSD: cost)

        case .scatterGather:
            // For scatter-gather, just pick the first viable candidate
            let best = candidates[0]
            let cost = estimateCost(model: best, duration: shot.duration)
            return RoutingDecision(
                provider: best.providerId, model: best.modelId,
                reason: "Scatter-gather primary",
                estimatedCostUSD: cost
            )
        }
    }

    /// For scatter-gather: return N distinct provider/model pairs.
    static func scatterTargets(
        shot: Shot,
        count: Int,
        availableProviders: [String]
    ) -> [(provider: String, model: String)] {
        let allModels = ProviderRegistry.shared.allModels
        var candidates = allModels.filter { availableProviders.contains($0.providerId) }

        if shot.referenceImageURL != nil {
            candidates = candidates.filter { $0.supportsImageToVideo }
        }
        if let d = shot.duration {
            candidates = candidates.filter { m in
                guard let max = m.maxDurationSeconds else { return true }
                return max >= d
            }
        }

        // Prioritize provider diversity
        var seen = Set<String>()
        var targets: [(provider: String, model: String)] = []

        // First pass: one model per provider
        for m in candidates {
            if !seen.contains(m.providerId) {
                seen.insert(m.providerId)
                targets.append((m.providerId, m.modelId))
                if targets.count >= count { break }
            }
        }

        // Second pass: fill remaining with additional models
        if targets.count < count {
            for m in candidates {
                let pair = "\(m.providerId)/\(m.modelId)"
                if !targets.contains(where: { "\($0.provider)/\($0.model)" == pair }) {
                    targets.append((m.providerId, m.modelId))
                    if targets.count >= count { break }
                }
            }
        }

        return targets
    }

    /// Determine which providers have configured API keys.
    static func availableProviders() -> [String] {
        ProviderRegistry.shared.all.filter { prov in
            (try? CLIKeychain.resolveKey(provider: prov.providerId, flagValue: nil)) != nil
        }.map { $0.providerId }
    }

    private static func estimateCost(model: CLIProviderModel, duration: Double?) -> Double? {
        guard let cost = model.costPerSecondUSD, let dur = duration else { return nil }
        return cost * dur
    }
}
