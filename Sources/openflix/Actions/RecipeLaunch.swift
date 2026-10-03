import Foundation
import OpenFlixKit

/// A recipe made ready to submit: arguments substituted, provider and model
/// checked. Shared by `openflix recipe run` and the `run_recipe` action, so a
/// recipe means the same thing whichever door it comes through.
struct RecipeLaunch {
    let recipe: CLIRecipe
    let provider: String
    let model: String
    let extraParams: [String: Any]

    /// - Parameter provided: argument values by name (`{{name}}` placeholders).
    /// - Throws: `RecipeArgError` (with its own code, which `recipe run`
    ///   reports) for a bad argument; `OpenFlixError` otherwise.
    static func prepare(_ recipe: CLIRecipe, provided: [String: String]) throws -> RecipeLaunch {
        var recipe = recipe
        let values = try RecipeArgResolver.resolve(args: recipe.args ?? [], provided: provided)
        recipe = recipe.substituting(values)

        guard let provider = recipe.provider, !provider.isEmpty else {
            throw OpenFlixError.invalidInput("Recipe has no provider set. Use: openflix recipe fork \(recipe.id) --provider <provider>")
        }
        guard let model = recipe.model, !model.isEmpty else {
            throw OpenFlixError.invalidInput("Recipe has no model set. Use: openflix recipe fork \(recipe.id) --model <model>")
        }
        let registered = try ProviderRegistry.shared.provider(for: provider)
        guard registered.models.contains(where: { $0.modelId == model }) else {
            throw OpenFlixError.invalidInput(VideoModelCatalog.retiredRefusal(model: model)
                ?? "Model '\(model)' not found for provider '\(provider)'. Run: openflix models --provider \(provider)")
        }

        var extras: [String: Any] = [:]
        if let json = recipe.parametersJSON, let data = json.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            extras = dict
        }
        return RecipeLaunch(recipe: recipe, provider: provider, model: model, extraParams: extras)
    }

    /// `prepare` for the action surfaces, where every refusal is an OpenFlixError.
    static func prepareForAction(_ recipe: CLIRecipe, provided: [String: String]) throws -> RecipeLaunch {
        do { return try prepare(recipe, provided: provided) }
        catch let e as RecipeArgError { throw OpenFlixError.invalidInput(e.errorDescription ?? "Invalid recipe argument") }
    }

    var negativePrompt: String? { recipe.negativePromptText.isEmpty ? nil : recipe.negativePromptText }

    /// Counts a generation against the stored recipe's stats.
    static func record(_ gen: CLIGeneration, againstRecipe id: String) {
        RecipeStore.shared.update(id: id) { r in
            r.generationCount += 1
            r.generationIds.append(gen.id)
            if let cost = gen.actualCostUSD ?? gen.estimatedCostUSD { r.totalCostUSD += cost }
        }
    }
}
