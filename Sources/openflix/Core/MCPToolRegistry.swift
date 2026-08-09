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
/// entry below carries an explicit `annotations:`.
///
/// The direction that matters is *not* "declare everything false". Every tool
/// that spends keeps `destructiveHint: true`, because a client uses that hint to
/// decide whether to ask the human first and MCP has no "costs money" hint;
/// annotating spend as non-destructive would make `generate` *less* guarded than
/// it is today.
enum MCPToolRegistry {

    // MARK: - Tools

    static let allTools: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: "generate",
            title: "Generate a video (spends money)",
            description: "Submit a video generation request, poll until complete, and download the result. Returns the full generation object. SPENDS THE USER'S OWN PROVIDER CREDIT and cannot be undone; the charge is subject to the local budget pre-flight and may be refused. Either pass provider+model, or route=\"smart\" to auto-select by community preference win rate.",
            inputSchema: objectSchema(
                required: ["prompt"],
                properties: [
                    "prompt": stringProp("Text prompt describing the video to generate"),
                    "provider": stringProp("Provider ID (fal, replicate, runway, luma, kling, minimax, local). Required unless route=\"smart\""),
                    "model": stringProp("Model ID (provider-specific). Required unless route=\"smart\""),
                    "route": stringProp("Set to \"smart\" to auto-select provider+model from community preference data"),
                    "category": stringProp("Category hint for smart routing (e.g. cinematic, anime, product)"),
                    "negative_prompt": stringProp("Negative prompt (what to avoid)"),
                    "width": intProp("Video width in pixels"),
                    "height": intProp("Video height in pixels"),
                    "duration_seconds": numberProp("Video duration in seconds"),
                    "aspect_ratio": stringProp("Aspect ratio (e.g. 16:9, 9:16)"),
                    "timeout": numberProp("Timeout in seconds (default 300)"),
                    "max_retries": intProp("Max retry attempts on failure (default 0)"),
                ]
            ),
            // Irreversible spend against a remote API. `destructiveHint` stays
            // pessimistic on purpose — see the type comment.
            annotations: MCPToolAnnotations(readOnly: false, destructive: true,
                                            idempotent: false, openWorld: true),
            outputSchema: generationSchema
        ),
        MCPToolDefinition(
            name: "generate_submit",
            title: "Submit a generation without waiting (spends money)",
            description: "Submit a video generation request without waiting. Returns a generation ID for later polling. SPENDS THE USER'S OWN PROVIDER CREDIT and cannot be undone. Either pass provider+model, or route=\"smart\" to auto-select by community preference win rate.",
            inputSchema: objectSchema(
                required: ["prompt"],
                properties: [
                    "prompt": stringProp("Text prompt describing the video"),
                    "provider": stringProp("Provider ID. Required unless route=\"smart\""),
                    "model": stringProp("Model ID. Required unless route=\"smart\""),
                    "route": stringProp("Set to \"smart\" to auto-select provider+model from community preference data"),
                    "category": stringProp("Category hint for smart routing"),
                    "negative_prompt": stringProp("Negative prompt"),
                    "width": intProp("Video width in pixels"),
                    "height": intProp("Video height in pixels"),
                    "duration_seconds": numberProp("Video duration in seconds"),
                    "aspect_ratio": stringProp("Aspect ratio"),
                ]
            ),
            annotations: MCPToolAnnotations(readOnly: false, destructive: true,
                                            idempotent: false, openWorld: true),
            outputSchema: generationSchema
        ),
        MCPToolDefinition(
            name: "generate_poll",
            title: "Poll a generation",
            description: "Poll the status of an existing generation. Returns current status and progress. Does not start new work and adds no new charge, but it does contact the provider and records the final cost of a generation that has just finished.",
            inputSchema: objectSchema(
                required: ["generation_id"],
                properties: [
                    "generation_id": stringProp("The generation ID to poll"),
                    "wait": boolProp("If true, block until generation completes"),
                    "timeout": numberProp("Timeout in seconds when waiting"),
                ]
            ),
            // Not read-only: a poll that finds a terminal state writes the
            // record and the spend ledger. Repeating it changes nothing further.
            annotations: MCPToolAnnotations(readOnly: false, destructive: false,
                                            idempotent: true, openWorld: true),
            outputSchema: generationSchema
        ),
        MCPToolDefinition(
            name: "list_generations",
            title: "List generations",
            description: "List generations with optional filtering by status, provider, or search term. Reads this machine's local generation store; makes no network call.",
            inputSchema: objectSchema(
                required: [],
                properties: [
                    "status": stringProp("Filter by status (queued, submitted, processing, succeeded, failed, cancelled)"),
                    "provider": stringProp("Filter by provider ID"),
                    "limit": intProp("Max number of results (default 20)"),
                    "search": stringProp("Search term to filter by prompt text"),
                ]
            ),
            annotations: .localRead,
            outputSchema: objectSchema(
                required: ["generations", "total", "returned"],
                properties: [
                    "generations": arrayProp("Matching generations", items: generationSchema),
                    "total": intProp("Number of generations matching the filters"),
                    "returned": intProp("Number actually returned after the limit"),
                ]
            )
        ),
        MCPToolDefinition(
            name: "get_generation",
            title: "Get one generation",
            description: "Get detailed information about a single generation from this machine's local store.",
            inputSchema: objectSchema(
                required: ["generation_id"],
                properties: [
                    "generation_id": stringProp("The generation ID"),
                ]
            ),
            annotations: .localRead,
            outputSchema: generationSchema
        ),
        MCPToolDefinition(
            name: "cancel_generation",
            title: "Cancel a generation",
            description: "Cancel an active (queued/submitted/processing) generation. Asks the provider to stop, then marks the local record cancelled. Work already billed is not refunded and the generation cannot be un-cancelled.",
            inputSchema: objectSchema(
                required: ["generation_id"],
                properties: [
                    "generation_id": stringProp("The generation ID to cancel"),
                ]
            ),
            // Irreversible, and a second call fails rather than being a no-op,
            // so `idempotentHint` stays false.
            annotations: MCPToolAnnotations(readOnly: false, destructive: true,
                                            idempotent: false, openWorld: true),
            outputSchema: objectSchema(
                required: ["status", "generation_id", "remote_cancelled"],
                properties: [
                    "status": stringProp("Always \"cancelled\""),
                    "generation_id": stringProp("The generation that was cancelled"),
                    "remote_cancelled": boolProp("True when the provider confirmed the cancel; false means local-only"),
                    "note": stringProp("Why the remote cancel did not happen, when it did not"),
                ]
            )
        ),
        MCPToolDefinition(
            name: "retry_generation",
            title: "Retry a failed generation (spends money)",
            description: "Retry a failed generation with the same parameters, including its reference image and extra params. This submits a NEW generation and SPENDS THE USER'S OWN PROVIDER CREDIT again.",
            inputSchema: objectSchema(
                required: ["generation_id"],
                properties: [
                    "generation_id": stringProp("The failed generation ID to retry"),
                ]
            ),
            annotations: MCPToolAnnotations(readOnly: false, destructive: true,
                                            idempotent: false, openWorld: true),
            outputSchema: generationSchema
        ),
        MCPToolDefinition(
            name: "list_providers",
            title: "List providers and models",
            description: "List available video generation providers and their models, including capabilities and pricing. Reads a built-in table; makes no network call and spends nothing.",
            inputSchema: objectSchema(required: [], properties: [:]),
            annotations: .localRead,
            outputSchema: objectSchema(
                required: ["providers", "count"],
                properties: [
                    "providers": arrayProp("Known provider/model pairs"),
                    "count": intProp("How many models are listed"),
                ]
            )
        ),
        MCPToolDefinition(
            name: "evaluate_quality",
            title: "Evaluate a finished video",
            description: "Run quality evaluation on a completed generation's downloaded video. The default \"heuristic\" evaluator is local and free; \"llm-vision\" calls a remote model and spends money. Either way the score is written to this machine's provider metrics.",
            inputSchema: objectSchema(
                required: ["generation_id"],
                properties: [
                    "generation_id": stringProp("The generation ID to evaluate"),
                    "evaluator": stringProp("Evaluator type: heuristic (default, local, free) or llm-vision (remote, paid)"),
                    "threshold": numberProp("Quality threshold (0-100)"),
                ]
            ),
            // Writes a metric, and llm-vision leaves the machine. Nothing is
            // destroyed, but repeating it moves the running average again.
            annotations: MCPToolAnnotations(readOnly: false, destructive: false,
                                            idempotent: false, openWorld: true),
            outputSchema: objectSchema(
                required: ["generation_id", "score", "evaluator", "passed"],
                properties: [
                    "generation_id": stringProp("The generation that was evaluated"),
                    "score": numberProp("Quality score, 0-100"),
                    "evaluator": stringProp("Which evaluator produced the score"),
                    "passed": boolProp("Whether the score met the threshold"),
                    "reasoning": stringProp("Evaluator explanation, when it produced one"),
                ]
            )
        ),
        MCPToolDefinition(
            name: "submit_feedback",
            title: "Score a generation (local only)",
            description: "Submit quality feedback (0-100 score) for a generation. Local-only: feeds this machine's provider metrics, never leaves the machine.",
            inputSchema: objectSchema(
                required: ["generation_id", "score"],
                properties: [
                    "generation_id": stringProp("The generation ID"),
                    "score": numberProp("Quality score (0-100)"),
                    "reason": stringProp("Optional reason for the score"),
                ]
            ),
            // openWorld: false is the load-bearing claim here — this is the tool
            // whose whole promise is that the score never leaves the machine.
            annotations: MCPToolAnnotations(readOnly: false, destructive: false,
                                            idempotent: false, openWorld: false),
            outputSchema: objectSchema(
                required: ["status", "generation_id", "provider", "model", "score"],
                properties: [
                    "status": stringProp("Always \"recorded\""),
                    "generation_id": stringProp("The generation the score was recorded against"),
                    "provider": stringProp("Provider the score was attributed to"),
                    "model": stringProp("Model the score was attributed to"),
                    "score": numberProp("The score recorded"),
                ]
            )
        ),
        MCPToolDefinition(
            name: "submit_vote",
            title: "Share a preference vote with the community",
            description: "Record a pairwise preference vote (winner beat loser) and share it with the community registry — the same data smart routing reads back. Sends only provider/model names and a category, never the prompt or the video; deduplicated server-side, safe to retry.",
            inputSchema: objectSchema(
                required: ["winner_generation_id", "loser_generation_id"],
                properties: [
                    "winner_generation_id": stringProp("Generation ID that was preferred"),
                    "loser_generation_id": stringProp("Generation ID it beat (must be a different provider/model)"),
                    "category": stringProp("Category hint (e.g. cinematic, anime, product)"),
                ]
            ),
            // Leaves the machine, and the registry dedupes — "safe to retry" in
            // the description and `idempotentHint: true` are the same claim.
            annotations: MCPToolAnnotations(readOnly: false, destructive: false,
                                            idempotent: true, openWorld: true),
            outputSchema: objectSchema(
                required: ["status", "winner_generation_id", "loser_generation_id", "accepted"],
                properties: [
                    "status": stringProp("Always \"shared\""),
                    "winner_generation_id": stringProp("The winning generation"),
                    "loser_generation_id": stringProp("The losing generation"),
                    "accepted": intProp("How many votes the registry accepted"),
                    "duplicates_ignored": intProp("How many were dropped as duplicates"),
                ]
            )
        ),
        MCPToolDefinition(
            name: "get_metrics",
            title: "Provider metrics",
            description: "Get this machine's provider performance metrics (quality, latency, cost, success rate). Local read.",
            inputSchema: objectSchema(
                required: [],
                properties: [
                    "provider": stringProp("Filter by provider ID"),
                    "sort": stringProp("Sort by: quality, latency, cost, success_rate (default: quality)"),
                ]
            ),
            annotations: .localRead,
            outputSchema: objectSchema(
                required: ["metrics", "count"],
                properties: [
                    "metrics": arrayProp("Per provider/model metrics"),
                    "count": intProp("How many rows were returned"),
                ]
            )
        ),
        MCPToolDefinition(
            name: "budget_status",
            title: "Budget status",
            description: "Get current budget status including daily spend, limits, and remaining budget. Local read — this is the gate every generation is checked against, so call it before spending.",
            inputSchema: objectSchema(required: [], properties: [:]),
            annotations: .localRead
        ),
        MCPToolDefinition(
            name: "project_run",
            title: "Look up a project (does not run it)",
            description: "Look up a multi-shot project by ID. NOTE: this tool does NOT execute the project — it returns the project's identity and the shell command that runs it. Execution spends money per shot and goes through the CLI's budget pre-flight, so it stays a deliberate `openflix project run <id>` rather than a single agent call.",
            inputSchema: objectSchema(
                required: ["project_id"],
                properties: [
                    "project_id": stringProp("The project ID to look up"),
                    "strategy": stringProp("Accepted for forward compatibility; ignored, because this tool does not execute"),
                    "evaluate": boolProp("Accepted for forward compatibility; ignored, because this tool does not execute"),
                ]
            ),
            // Honest about what the implementation does today, which is read one
            // record. The name is kept because clients may already reference it.
            annotations: .localRead,
            outputSchema: objectSchema(
                required: ["project_id", "name", "status"],
                properties: [
                    "project_id": stringProp("The project looked up"),
                    "name": stringProp("Project name"),
                    "status": stringProp("How to actually run it"),
                ]
            )
        ),
        MCPToolDefinition(
            name: "health_check",
            title: "Which providers are configured",
            description: "Report which providers have a usable API key on this machine. Reads the local Keychain only — it does not contact any provider, so a provider listed as configured may still be down.",
            inputSchema: objectSchema(required: [], properties: [:]),
            annotations: .localRead,
            outputSchema: objectSchema(
                required: ["providers", "configured_count", "total_count"],
                properties: [
                    "providers": arrayProp("Every known provider with whether a key is present"),
                    "configured_count": intProp("How many have a key"),
                    "total_count": intProp("How many providers exist"),
                ]
            )
        ),
    ]

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

    // MARK: - JSON Schema Helpers

    /// One shape for every tool that returns a generation record. The five keys
    /// marked required are the five `CLIGeneration.jsonRepresentation` always
    /// writes; everything else is conditional on the record, so it is declared
    /// but not required.
    static let generationSchema: [String: AnyCodableValue] = objectSchema(
        required: ["id", "status", "provider", "model", "prompt"],
        properties: [
            "id": stringProp("Generation ID"),
            "status": stringProp("queued, submitted, processing, succeeded, failed or cancelled"),
            "provider": stringProp("Provider that ran it"),
            "model": stringProp("Model that ran it"),
            "prompt": stringProp("The prompt that was submitted"),
            "retry_count": intProp("How many times it has been retried"),
            "created_at": stringProp("ISO-8601 creation time"),
            "local_path": stringProp("Path to the downloaded video, once downloaded"),
            "remote_video_url": stringProp("Provider-hosted video URL, once available"),
            "estimated_cost_usd": numberProp("Pre-flight cost estimate in USD"),
            "actual_cost_usd": numberProp("Billed cost in USD, once known"),
            "error_message": stringProp("Why it failed, when it failed"),
        ]
    )

    private static func objectSchema(required: [String], properties: [String: [String: AnyCodableValue]]) -> [String: AnyCodableValue] {
        var schema: [String: AnyCodableValue] = [
            "type": .string("object"),
            "properties": .dictionary(properties.mapValues { .dictionary($0) }),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        return schema
    }

    private static func stringProp(_ description: String) -> [String: AnyCodableValue] {
        ["type": .string("string"), "description": .string(description)]
    }

    private static func intProp(_ description: String) -> [String: AnyCodableValue] {
        ["type": .string("integer"), "description": .string(description)]
    }

    private static func numberProp(_ description: String) -> [String: AnyCodableValue] {
        ["type": .string("number"), "description": .string(description)]
    }

    private static func boolProp(_ description: String) -> [String: AnyCodableValue] {
        ["type": .string("boolean"), "description": .string(description)]
    }

    private static func arrayProp(_ description: String,
                                  items: [String: AnyCodableValue]? = nil) -> [String: AnyCodableValue] {
        var prop: [String: AnyCodableValue] = [
            "type": .string("array"),
            "description": .string(description),
        ]
        if let items { prop["items"] = .dictionary(items) }
        return prop
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
        Finally call `submit_vote` with the winner's and loser's generation IDs — that vote is what \
        `route: "smart"` reads back, for this machine and for everyone else.
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
