import Foundation
import OpenFlixKit

/// What a spending action will do and cost, worked out before it runs.
///
/// A quote is what lets a person approve a spend they can see. It resolves
/// everything that could otherwise change between approval and execution —
/// `route: "smart"` becomes the concrete provider and model it picked — and
/// the execution then runs the *resolved* arguments, so the thing approved is
/// the thing billed.
struct SpendQuote {
    let action: String
    /// The arguments to execute: the caller's, with routing resolved.
    let resolvedArguments: [String: AnyCodableValue]
    let estimatedCostUSD: Double
    /// One line a person can say yes or no to.
    let summary: String
    let provider: String
    let model: String
}

extension CLIActions {

    /// Spending actions that can be quoted, and therefore run by an agent over
    /// the bridge. The others spend in ways one number cannot cover yet
    /// (`project_run` is a graph with its own plan and ceiling; `evaluate_quality`
    /// bills a different account) or block for minutes (`generate` — use
    /// `generate_submit` and poll).
    static let quotableActions: Set<String> = ["generate_submit", "retry_generation", "run_recipe"]

    /// Providers that cost nothing to call, so a $0 quote is true rather than
    /// a pricing gap.
    static let freeProviders: Set<String> = ["local"]

    /// Prices a spending action without running it. Validates the arguments
    /// through the same schema as `run`.
    static func quote(_ name: String, arguments: [String: AnyCodableValue]) async throws -> SpendQuote {
        guard let descriptor = CLIActionCatalog.descriptor(named: name) else {
            throw OpenFlixError.invalidResponse("Unknown tool: \(name)")
        }
        try ActionValidator.validate(JSONValue(.dictionary(arguments)), against: descriptor.inputSchema)
        guard quotableActions.contains(name) else {
            throw ActionInputError(argument: nil, message: "'\(name)' cannot be quoted. Quotable actions: \(quotableActions.sorted().joined(separator: ", "))")
        }

        switch name {
        case "generate_submit":
            let (provider, model, _) = try await resolveProviderModel(arguments)
            var resolved = arguments
            resolved["provider"] = .string(provider)
            resolved["model"] = .string(model)
            resolved["route"] = nil
            let duration = optionalDouble(arguments, "duration_seconds")
            return try priced(action: name, provider: provider, model: model,
                              durationSeconds: duration, aspectRatio: optionalString(arguments, "aspect_ratio"),
                              resolved: resolved)

        case "retry_generation":
            let id = try requireIdentifier(arguments, "generation_id")
            guard let gen = GenerationStore.shared.get(id) else {
                throw OpenFlixError.generationNotFound(id)
            }
            guard gen.status == .failed else {
                throw OpenFlixError.invalidResponse("Can only retry failed generations (current: \(gen.status.rawValue))")
            }
            return try priced(action: name, provider: gen.provider, model: gen.model,
                              durationSeconds: gen.durationSeconds, aspectRatio: gen.aspectRatio,
                              resolved: arguments)

        case "run_recipe":
            let id = try requireIdentifier(arguments, "recipe_id")
            guard let stored = RecipeStore.shared.get(id) else {
                throw OpenFlixError.invalidInput("Recipe '\(id)' not found. See list_recipes.")
            }
            let launch = try RecipeLaunch.prepareForAction(stored, provided: recipeArgumentValues(arguments))
            return try priced(action: name, provider: launch.provider, model: launch.model,
                              durationSeconds: launch.recipe.durationSeconds,
                              aspectRatio: launch.recipe.aspectRatio, resolved: arguments)

        default:
            throw ActionInputError(argument: nil, message: "'\(name)' cannot be quoted")
        }
    }

    /// The same estimate the engine's budget gate uses, so a quote and the
    /// gate agree about what a call costs.
    private static func priced(action: String, provider: String, model: String,
                               durationSeconds: Double?, aspectRatio: String?,
                               resolved: [String: AnyCodableValue]) throws -> SpendQuote {
        _ = try ProviderRegistry.shared.provider(for: provider)
        let info = ProviderRegistry.shared.allModels.first { $0.providerId == provider && $0.modelId == model }
        let estimate = GenerationEngine.preflightEstimate(durationSeconds: durationSeconds,
                                                          costPerSecondUSD: info?.costPerSecondUSD)
        guard estimate.isFinite, estimate >= 0 else {
            throw OpenFlixError.budgetExceeded("the cost of \(provider) \(model) could not be estimated")
        }
        // A $0 estimate for a paid provider means a missing price, not a free
        // call — and a spending cap cannot bound what it cannot price.
        if estimate == 0 && !freeProviders.contains(provider) {
            throw OpenFlixError.budgetExceeded("\(provider) \(model) has no known price, so an agent cannot spend on it under a daily cap. Pick a priced model (see list_providers).")
        }

        let billed = durationSeconds ?? GenerationEngine.defaultBillableDurationSeconds
        var parts = ["\(provider) \(model)", "\(trim(billed))s"]
        if let aspectRatio { parts.append(aspectRatio) }
        parts.append(String(format: "est $%.2f", estimate))
        let verb = action == "retry_generation" ? "Retry" : (action == "run_recipe" ? "Run recipe" : "Generate")
        return SpendQuote(action: action, resolvedArguments: resolved, estimatedCostUSD: estimate,
                          summary: "\(verb): " + parts.joined(separator: " · "),
                          provider: provider, model: model)
    }

    private static func trim(_ seconds: Double) -> String {
        seconds.isFinite && seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)
    }
}
