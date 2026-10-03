import Foundation
import OpenFlixKit

/// Recipes and playback as actions: the rest of the suite an agent needs so
/// it never falls back to writing raw prompts it has no evidence for, or to
/// playing video in some other player.
extension CLIActions {

    /// Swapped in tests so nothing opens an app.
    nonisolated(unsafe) static var playback = PlaybackLauncher()

    static func toolListRecipes(_ args: [String: AnyCodableValue]) -> [String: Any] {
        var recipes = RecipeStore.shared.all()
        if let search = optionalString(args, "search")?.lowercased(), !search.isEmpty {
            recipes = recipes.filter {
                $0.name.lowercased().contains(search) || $0.promptText.lowercased().contains(search)
            }
        }
        return ["recipes": recipes.map { MCPServer.recipeJSON($0) }, "count": recipes.count]
    }

    static func toolRunRecipe(_ args: [String: AnyCodableValue]) async throws -> [String: Any] {
        let id = try requireIdentifier(args, "recipe_id")
        guard let stored = RecipeStore.shared.get(id) else {
            throw OpenFlixError.invalidInput("Recipe '\(id)' not found. See list_recipes.")
        }
        let launch = try RecipeLaunch.prepareForAction(stored, provided: recipeArgumentValues(args))
        let gen = try await GenerationEngine.submit(
            prompt: launch.recipe.promptText,
            negativePrompt: launch.negativePrompt,
            provider: launch.provider,
            model: launch.model,
            durationSeconds: launch.recipe.durationSeconds,
            aspectRatio: launch.recipe.aspectRatio,
            width: launch.recipe.widthPx,
            height: launch.recipe.heightPx,
            extraParams: launch.extraParams)
        RecipeLaunch.record(gen, againstRecipe: id)
        var result = gen.jsonRepresentation
        result["recipe_id"] = id
        return result
    }

    /// `args` values are strings or numbers in JSON; recipe arguments are text.
    static func recipeArgumentValues(_ args: [String: AnyCodableValue]) throws -> [String: String] {
        guard case .dictionary(let object)? = args["args"] else { return [:] }
        var values: [String: String] = [:]
        for (name, value) in object {
            switch value {
            case .string(let v): values[name] = v
            case .int(let v): values[name] = String(v)
            case .double(let v) where v.isFinite: values[name] = String(v)
            case .bool(let v): values[name] = String(v)
            default:
                throw ActionInputError(argument: "args", message: "'args.\(name)' must be a string or number")
            }
        }
        return values
    }

    static func toolPlayVideo(_ args: [String: AnyCodableValue]) async throws -> [String: Any] {
        let target = try PlaybackLauncher.target(path: optionalString(args, "path"),
                                                 url: optionalString(args, "url"),
                                                 generationId: optionalString(args, "generation_id"))
        return try await playback.play(target, seekSeconds: optionalDouble(args, "seek_seconds"))
    }

    static func toolControlPlayback(_ args: [String: AnyCodableValue]) throws -> [String: Any] {
        try playback.control(try requireString(args, "action"))
    }

    // MARK: - Showing a result to the user

    /// Actions whose result is a generation record.
    static let generationResults: Set<String> = [
        "generate", "generate_submit", "generate_poll", "get_generation", "retry_generation", "run_recipe",
    ]

    /// Adds how to show a finished generation to the user, so an agent's next
    /// step is the OpenFlix player — or its own chat attachment — rather than
    /// `open`, VLC or a bare path.
    ///
    /// `MEDIA:<absolute path>` on its own line is how OpenClaw and Hermes both
    /// attach a file to a chat reply.
    static func withPlaybackHints(_ result: [String: Any]) -> [String: Any] {
        guard let id = result["id"] as? String else { return result }
        var out = result
        if let path = result["local_path"] as? String, !path.isEmpty {
            out["show_user"] = [
                "on_this_mac": ["tool": "play_video", "arguments": ["generation_id": id],
                                "cli": "openflix play \(id)"] as [String: Any],
                "in_chat": "MEDIA:\(path)",
            ] as [String: Any]
        } else if let status = result["status"] as? String, !["failed", "cancelled"].contains(status) {
            out["show_user"] = ["when_ready": "Poll with generate_poll (generation_id \(id), wait: true); once it has a local_path, play it with play_video."]
        }
        return out
    }
}
