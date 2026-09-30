import Foundation
import OpenFlixKit

/// Registry of all MCP tools, resources and prompts exposed by OpenFlix.
///
/// **On annotations.** Two of the four `ToolAnnotations` schema defaults are the
/// pessimistic value — an unannotated tool is assumed **destructive** and
/// **open-world** — so before this table existed, `list_providers` (a local
/// lookup of a static price table) and `generate` (an irreversible charge
/// against the user's provider credit) looked identical to a client. That is the
/// cheapest safety win available on this surface, and it is the reason every
/// tool carries annotations — now derived from each action's declared effect in
/// `CLIActionCatalog` rather than written per tool.
///
/// The direction that matters is *not* "declare everything false". Every tool
/// that spends keeps `destructiveHint: true`, because a client uses that hint to
/// decide whether to ask the human first and MCP has no "costs money" hint;
/// annotating spend as non-destructive would make `generate` *less* guarded than
/// it is today.
enum MCPToolRegistry {

    // MARK: - Tools

    /// Derived from `CLIActionCatalog`, the one description of every action.
    /// The annotations follow from each action's effect; see the type comment
    /// for why spend is always destructive.
    static let allTools: [MCPToolDefinition] = CLIActionCatalog.all.map(MCPToolDefinition.init)

    /// Tool names cross the model boundary, where a dot is illegal. Asserted in
    /// tests, but kept here so a new tool fails the check next to its definition.
    static var allToolNamesAreWellFormed: Bool {
        allTools.allSatisfy { MCPToolName.isWellFormed($0.name) }
    }

    // MARK: - Resources

    static let allResources: [MCPResourceDefinition] = [
        MCPResourceDefinition(
            uri: "openflix://providers",
            name: "Available Providers",
            description: "List of configured video generation providers with their models and capabilities",
            mimeType: "application/json"
        ),
        MCPResourceDefinition(
            uri: "openflix://metrics",
            name: "Provider Metrics",
            description: "Current provider performance metrics (quality, latency, cost, success rate)",
            mimeType: "application/json"
        ),
        MCPResourceDefinition(
            uri: "openflix://budget",
            name: "Budget Status",
            description: "Current budget status including daily spend and limits",
            mimeType: "application/json"
        ),
    ]

    /// The unbounded space — every generation and every recipe on this machine —
    /// reached by id rather than enumerated. This is what resource templates are
    /// for, and it is why `resources/list` needs no pagination cursor.
    ///
    /// These are the same strings the OpenFlix app accepts as `openflix://` deep
    /// links, so one URI is simultaneously a thing an agent can `resources/read`
    /// and a link a human can click to open the record in the app.
    static let allResourceTemplates: [MCPResourceTemplateDefinition] = [
        MCPResourceTemplateDefinition(
            uriTemplate: "openflix://generation/{id}",
            name: "Generation",
            description: "One generation record from this machine's store, by ID. Also a clickable openflix:// deep link.",
            mimeType: "application/json"
        ),
        MCPResourceTemplateDefinition(
            uriTemplate: "openflix://recipe/{id}",
            name: "Recipe",
            description: "One saved .openflix recipe, by ID, including its declared arguments. Also a clickable openflix:// deep link.",
            mimeType: "application/json"
        ),
    ]

    // MARK: - Prompts
    //
    // A recipe in OpenFlix *is* an MCP prompt: `promptText` with `{{name}}`
    // placeholders plus a declared `[RecipeArg]` of name/type/default/choices,
    // against a named template with typed arguments a client surfaces as a slash
    // command. The CLI owns the `.openflix` recipe format, so this is a
    // translation rather than a feature:
    //
    //     RecipeArg.name        → PromptArgument.name
    //     RecipeArg.description → PromptArgument.description
    //     RecipeArg.default     → absent ⇒ PromptArgument.required == true
    //     RecipeArg.choices     → completion/complete values
    //     recipe.promptText     → the rendered PromptMessage
    //
    // Rendering a recipe **does not generate anything**. It returns the text a
    // generation would use; submitting stays `tools/call generate`, which is the
    // only path through `GenerationEngine.submit` and therefore the only path
    // through the budget pre-flight, the prompt-safety check, the
    // reference-image rule and the hooks.

    /// Prefix for a recipe-backed prompt. `recipe_<id>` is stable across renames
    /// and unique by construction.
    static let recipePromptPrefix = "recipe_"

    /// How many recipes are advertised. Bounded because `prompts/list` has no
    /// pagination cursor here and a client puts this list in front of a human as
    /// a command menu.
    static let recipePromptLimit = 50

    /// The one prompt that spells out the loop this server exists for: generate,
    /// look, vote, let smart routing learn.
    static let comparePrompt = MCPPromptDefinition(
        name: "compare_providers",
        title: "Compare two providers on one prompt",
        description: "Generate the same prompt on two providers, compare them, and feed the winner back into community smart routing.",
        arguments: [
            .init(name: "prompt", description: "What to generate, in the user's words.", required: true),
            .init(name: "provider_a", description: "First provider ID (fal, replicate, runway, luma, kling, minimax, local).", required: false),
            .init(name: "provider_b", description: "Second provider ID.", required: false),
        ],
        recipeId: nil)

    /// A zero-argument prompt: useful on its own, and the shape a client can
    /// exercise without filling in a form.
    static let budgetPrompt = MCPPromptDefinition(
        name: "budget_check",
        title: "What can I afford?",
        description: "Report the current budget, what it allows, and what the cheapest configured provider would cost.",
        arguments: [],
        recipeId: nil)

    static let builtInPrompts: [MCPPromptDefinition] = [comparePrompt, budgetPrompt]

    static func prompt(for recipe: CLIRecipe) -> MCPPromptDefinition {
        MCPPromptDefinition(
            name: "\(recipePromptPrefix)\(recipe.id)",
            title: recipe.name,
            description: describe(recipe),
            arguments: (recipe.args ?? []).map { arg in
                MCPPromptDefinition.Argument(
                    name: arg.name,
                    description: describe(arg),
                    // The mapping that carries the most weight: a recipe arg with
                    // no declared default has no value to fall back to, which is
                    // exactly what `required` means to a prompt client.
                    required: arg.defaultValue == nil,
                    choices: arg.choices ?? [])
            },
            recipeId: recipe.id)
    }

    static func allPrompts(recipes: [CLIRecipe]) -> [MCPPromptDefinition] {
        builtInPrompts + recipes.prefix(recipePromptLimit).map(prompt(for:))
    }

    static func findPrompt(named name: String, recipes: [CLIRecipe]) -> MCPPromptDefinition? {
        allPrompts(recipes: recipes).first { $0.name == name }
    }

    private static func describe(_ recipe: CLIRecipe) -> String {
        var parts = ["A saved OpenFlix recipe."]
        if let provider = recipe.provider {
            let model = recipe.model.map { " / \($0)" } ?? ""
            parts.append("Prefers \(provider)\(model).")
        }
        if recipe.generationCount > 0 {
            parts.append("Used \(recipe.generationCount) time\(recipe.generationCount == 1 ? "" : "s").")
        }
        parts.append("Renders the prompt text only — call the generate tool to actually submit it.")
        return parts.joined(separator: " ")
    }

    private static func describe(_ arg: RecipeArg) -> String {
        var parts: [String] = []
        if let description = arg.description, !description.isEmpty {
            parts.append(description)
        }
        if let choices = arg.choices, !choices.isEmpty {
            parts.append("One of: \(choices.joined(separator: ", ")).")
        } else {
            parts.append("Type: \(arg.type).")
        }
        if let defaultValue = arg.defaultValue {
            parts.append("Defaults to \(defaultValue.stringValue).")
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Prompt rendering

/// Renders one prompt into a `prompts/get` payload.
///
/// Pure: `recipes` is passed in rather than fetched, so every branch is testable
/// without touching `~/.openflix`.
enum MCPPromptRenderer {

    enum Failure: Error, Equatable {
        case unknownPrompt(String)
        case missingArgument(prompt: String, argument: String)
        case invalidArgument(String)

        var message: String {
            switch self {
            case .unknownPrompt(let name):
                return "Unknown prompt: \(name)"
            case .missingArgument(let prompt, let argument):
                return "Prompt '\(prompt)' requires the argument '\(argument)'."
            case .invalidArgument(let detail):
                return detail
            }
        }
    }

    static func render(name: String,
                       arguments: AnyCodableValue?,
                       recipes: [CLIRecipe]) -> Result<AnyCodableValue, Failure> {
        guard let prompt = MCPToolRegistry.findPrompt(named: name, recipes: recipes) else {
            return .failure(.unknownPrompt(name))
        }

        let provided = stringArguments(arguments)
        for argument in prompt.arguments where argument.required {
            let value = provided[argument.name]?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value, !value.isEmpty else {
                return .failure(.missingArgument(prompt: prompt.name, argument: argument.name))
            }
        }

        if let recipeId = prompt.recipeId {
            guard let recipe = recipes.first(where: { $0.id == recipeId }) else {
                return .failure(.unknownPrompt(name))
            }
            return renderRecipe(recipe, prompt: prompt, provided: provided)
        }

        switch prompt.name {
        case MCPToolRegistry.comparePrompt.name:
            return .success(result(description: prompt.description,
                                   text: compareText(prompt: provided["prompt"] ?? "",
                                                     providerA: provided["provider_a"],
                                                     providerB: provided["provider_b"])))
        case MCPToolRegistry.budgetPrompt.name:
            return .success(result(description: prompt.description, text: budgetText))
        default:
            return .failure(.unknownPrompt(name))
        }
    }

    // MARK: Recipes

    private static func renderRecipe(_ recipe: CLIRecipe,
                                     prompt: MCPPromptDefinition,
                                     provided: [String: String]) -> Result<AnyCodableValue, Failure> {
        let declaredArgs = recipe.args ?? []
        // Only pass through arguments the recipe actually declares: the resolver
        // rejects unknown names, and an agent that adds a stray key should get a
        // rendered prompt rather than a hard failure it cannot act on.
        let declared = Set(declaredArgs.map(\.name))
        let filtered = provided.filter { declared.contains($0.key) }

        let values: [String: String]
        do {
            values = try RecipeArgResolver.resolve(args: declaredArgs, provided: filtered)
        } catch let error as RecipeArgError {
            if case .missingArg(let name) = error {
                return .failure(.missingArgument(prompt: prompt.name, argument: name))
            }
            return .failure(.invalidArgument(error.localizedDescription))
        } catch {
            return .failure(.invalidArgument("Could not resolve recipe arguments."))
        }

        // Through **the kit's** resolver, never a second `{{name}}` implementation.
        // `substitute` is single-pass on purpose: its own comment records that a
        // per-key loop rescanned already-substituted text, so an argument *value*
        // containing `{{other}}` was expanded or not depending on dictionary
        // order. An agent supplies these values, so single-pass is an
        // anti-injection property and this is precisely the path that must not
        // fork.
        let promptText = RecipeArgResolver.substitute(recipe.promptText, values: values)
        let negative = RecipeArgResolver.substitute(recipe.negativePromptText, values: values)

        var lines = ["Recipe \"\(recipe.name)\" (openflix://recipe/\(recipe.id))", "", promptText]
        if !negative.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(contentsOf: ["", "Negative prompt: \(negative)"])
        }
        var settings: [String] = []
        if let provider = recipe.provider { settings.append("provider \(provider)") }
        if let model = recipe.model { settings.append("model \(model)") }
        if let aspect = recipe.aspectRatio { settings.append("aspect \(aspect)") }
        if let duration = recipe.durationSeconds, duration.isFinite {
            settings.append("duration \(trimNumber(duration))s")
        }
        if !settings.isEmpty {
            lines.append(contentsOf: ["", "Preferred settings: \(settings.joined(separator: ", "))."])
        }
        lines.append(contentsOf: ["", generationNote])

        return .success(result(description: prompt.description,
                               text: lines.joined(separator: "\n")))
    }

    static let generationNote =
        "This is the prompt text only — rendering a prompt never submits anything. To actually generate it, call the `generate` tool (or `generate_submit`), which spends the user's own provider credit and is checked against the local budget first. Confirm with the user before spending."

    // MARK: Built-ins

    private static func compareText(prompt: String, providerA: String?, providerB: String?) -> String {
        let pair: String
        if let a = providerA, let b = providerB, !a.isEmpty, !b.isEmpty {
            pair = "Use provider \"\(a)\" for the first and \"\(b)\" for the second."
        } else {
            pair = "Pick two different configured providers — call `health_check` to see which ones have keys, and `list_providers` for their models and per-second pricing."
        }
        return """
        Compare two video providers on this prompt, then feed the result back into routing:

        \(prompt)

        How: \(pair) Call `budget_status` first and tell the user what the two generations will \
        cost before spending anything — each `generate` call charges their own provider credit and \
        cannot be undone. Then call `generate` twice with the same prompt and the same duration and \
        aspect ratio, so the only variable is the provider. When both come back, report each one's \
        `local_path`, `actual_cost_usd` and elapsed time, and ask the user which they prefer. \
        Once the user has chosen, call `submit_vote` with the winner's and loser's generation IDs \
        and `origin: "owner_relayed"` — that vote is what `route: "smart"` reads back, for this \
        machine and for everyone else. If the user does not pick one, do not vote: the pool is \
        human preference, and your own judgment is refused.
        """
    }

    private static let budgetText = """
    Report what this machine can currently afford to generate. Call `budget_status` for today's \
    spend and the daily, per-generation and monthly limits; call `health_check` to see which \
    providers actually have a key; call `list_providers` for per-second pricing. Then say plainly: \
    how much is left today, which configured provider is cheapest per second, and roughly how many \
    seconds of video that leaves. If no budget is set, say so — an unset limit means nothing is \
    stopping a generation from spending.
    """

    // MARK: Shapes

    private static func result(description: String, text: String) -> AnyCodableValue {
        .dictionary([
            "description": .string(description),
            "messages": .array([
                .dictionary([
                    "role": .string("user"),
                    "content": .dictionary(["type": .string("text"), "text": .string(text)]),
                ]),
            ]),
        ])
    }

    /// `prompts/get` arguments are a flat string map on the wire; numbers and
    /// booleans are accepted and stringified so a JSON-typed client still works.
    static func stringArguments(_ value: AnyCodableValue?) -> [String: String] {
        guard let object = value?.objectValue else { return [:] }
        var result: [String: String] = [:]
        for (key, raw) in object {
            switch raw {
            case .string(let s): result[key] = s
            case .int(let i):    result[key] = String(i)
            case .double(let d): if d.isFinite { result[key] = trimNumber(d) }
            case .bool(let b):   result[key] = b ? "true" : "false"
            default:             break
            }
        }
        return result
    }

    static func trimNumber(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
        return String(value)
    }
}

// MARK: - Completion

/// `completion/complete` — argument autocompletion for prompt arguments.
///
/// The only completable values this server has are a recipe enum argument's
/// declared `choices`, and that is exactly the payoff for having prompts: a
/// recipe declaring `style: enum [noir, anime, documentary]` offers those three
/// in a client's argument field instead of making the user guess. Any other
/// reference completes to nothing, which is a valid answer.
enum MCPCompletion {

    /// The spec caps a completion at 100 values.
    static let maxValues = 100

    static func complete(ref: AnyCodableValue?,
                         argumentName: String,
                         value: String,
                         recipes: [CLIRecipe]) -> AnyCodableValue {
        guard ref?["type"]?.stringValue == "ref/prompt",
              let promptName = ref?["name"]?.stringValue,
              let prompt = MCPToolRegistry.findPrompt(named: promptName, recipes: recipes),
              let argument = prompt.arguments.first(where: { $0.name == argumentName }),
              !argument.choices.isEmpty else {
            return payload(values: [], total: 0)
        }

        let needle = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = needle.isEmpty
            ? argument.choices
            : argument.choices.filter { $0.lowercased().hasPrefix(needle) }

        return payload(values: Array(matches.prefix(maxValues)), total: matches.count)
    }

    private static func payload(values: [String], total: Int) -> AnyCodableValue {
        .dictionary([
            "completion": .dictionary([
                "values": .array(values.map { .string($0) }),
                "total": .int(total),
                "hasMore": .bool(total > values.count),
            ]),
        ])
    }
}
