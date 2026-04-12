import ArgumentParser
import Foundation

// MARK: - Recipe subcommand group

struct RecipeGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recipe",
        abstract: "Create, run, fork, and share video recipes",
        discussion: """
        A recipe captures everything needed to reproduce a video generation:
        prompt, model, parameters, seed, and provenance.

        WORKFLOW
          openflix recipe init "prompt" --provider fal --model fal-ai/veo3
          openflix recipe run <recipe-id> --wait
          openflix recipe export <recipe-id> -o recipe.openflix
          openflix recipe fork <recipe-id> --name "my version"
        """,
        subcommands: [
            RecipeInit.self,
            RecipeShow.self,
            RecipeListCmd.self,
            RecipeExport.self,
            RecipeImport.self,
            RecipeFork.self,
            RecipeRun.self,
            RecipeBenchmark.self,
            RecipePublish.self,
            RecipeSearch.self,
        ]
    )
}

// MARK: - recipe init

struct RecipeInit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Create a new recipe from a prompt and options"
    )

    @Argument(help: "Text prompt describing the video to generate")
    var prompt: String

    @Option(name: .long, help: "Recipe name (defaults to first 50 chars of prompt)")
    var name: String?

    @Option(name: .long, help: "Provider ID (replicate, fal, runway, luma, kling, minimax)")
    var provider: String?

    @Option(name: .long, help: "Model ID (use 'openflix models --provider <id>' to list)")
    var model: String?

    @Option(name: .long, help: "Duration in seconds")
    var duration: Double?

    @Option(name: .long, help: "Aspect ratio (e.g. 16:9, 9:16, 1:1)")
    var aspectRatio: String?

    @Option(name: .long, help: "Output width in pixels")
    var width: Int?

    @Option(name: .long, help: "Output height in pixels")
    var height: Int?

    @Option(name: .long, help: "Negative prompt (what to avoid)")
    var negativePrompt: String?

    @Option(name: .long, help: "Seed for reproducibility")
    var seed: Int?

    @Option(name: .long, help: "Extra parameters as key=value pairs (e.g. audio=true seed=42)")
    var param: [String] = []

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Output.failMessage("Prompt cannot be empty.", code: "invalid_input")
        }

        let recipeName = name ?? String(prompt.prefix(50))

        // Parse extra params to JSON string
        var parametersJSON: String? = nil
        if !param.isEmpty {
            var extras: [String: Any] = [:]
            for kv in param {
                let parts = kv.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let key = parts[0], val = parts[1]
                if val == "true" || val == "false" {
                    extras[key] = (val == "true")
                } else if let n = Int(val) {
                    extras[key] = n
                } else if let n = Double(val) {
                    extras[key] = n
                } else {
                    extras[key] = val
                }
            }
            if !extras.isEmpty,
               let data = try? JSONSerialization.data(withJSONObject: extras) {
                parametersJSON = String(data: data, encoding: .utf8)
            }
        }

        let recipe = CLIRecipe(
            name: recipeName,
            promptText: prompt,
            negativePromptText: negativePrompt ?? "",
            provider: provider,
            model: model,
            aspectRatio: aspectRatio,
            durationSeconds: duration,
            widthPx: width,
            heightPx: height,
            seed: seed,
            parametersJSON: parametersJSON
        )

        RecipeStore.shared.save(recipe)
        Output.emitDict(recipe.jsonRepresentation)
    }
}

// MARK: - recipe show

struct RecipeShow: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show recipe details by ID or .openflix file"
    )

    @Argument(help: "Recipe ID or path to .openflix file")
    var identifier: String

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        // If identifier ends with .openflix, read as bundle file
        if identifier.hasSuffix(".openflix") {
            let path = (identifier as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else {
                Output.failMessage("File not found: \(identifier)", code: "not_found")
            }
            do {
                let bundle = try RecipeBundle.decode(fromFile: url)
                var bundleDict: [String: Any] = [
                    "format_version": bundle.formatVersion,
                    "exported_at": ISO8601DateFormatter().string(from: bundle.exportedAt),
                    "recipe_count": bundle.recipes.count,
                ]
                if let author = bundle.author { bundleDict["author"] = author }
                var recipeDicts: [[String: Any]] = []
                for exported in bundle.recipes {
                    let temp = CLIRecipe(from: exported)
                    recipeDicts.append(temp.jsonRepresentation)
                }
                bundleDict["recipes"] = recipeDicts
                Output.emitDict(bundleDict)
            } catch {
                Output.failMessage("Failed to read bundle: \(error.localizedDescription)", code: "invalid_input")
            }
            return
        }

        // Otherwise look up by ID
        guard let recipe = RecipeStore.shared.get(identifier) else {
            Output.failMessage("Recipe '\(identifier)' not found.", code: "not_found")
        }
        Output.emitDict(recipe.jsonRepresentation)
    }
}

// MARK: - recipe list

struct RecipeListCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List saved recipes"
    )

    @Option(name: .long, help: "Maximum number of recipes to return (default: 50)")
    var limit: Int = 50

    @Option(name: .long, help: "Search query to filter by name or prompt")
    var search: String?

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        let recipes: [CLIRecipe]
        if let query = search {
            recipes = Array(RecipeStore.shared.search(query: query).prefix(limit))
        } else {
            recipes = Array(RecipeStore.shared.all().prefix(limit))
        }

        Output.emitArray(recipes.map { $0.jsonRepresentation })
    }
}

// MARK: - recipe export

struct RecipeExport: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export a recipe to a portable .openflix bundle file"
    )

    @Argument(help: "Recipe ID to export")
    var recipeId: String

    @Option(name: [.short, .long], help: "Output file path (defaults to <recipe-name>.openflix)")
    var output: String?

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        guard let recipe = RecipeStore.shared.get(recipeId) else {
            Output.failMessage("Recipe '\(recipeId)' not found.", code: "not_found")
        }

        // Find best generation from the recipe's generation IDs
        var bestGen: CLIGeneration? = nil
        for genId in recipe.generationIds {
            if let gen = GenerationStore.shared.get(genId),
               gen.status == .succeeded {
                if bestGen == nil {
                    bestGen = gen
                } else if let existing = bestGen,
                          let existingDate = existing.completedAt,
                          let newDate = gen.completedAt,
                          newDate > existingDate {
                    bestGen = gen
                }
            }
        }

        let exported = recipe.toExported(bestGen: bestGen)
        let bundle = RecipeBundle(
            exportedAt: Date(),
            author: nil,
            recipes: [exported]
        )

        let outputPath: String
        if let o = output {
            outputPath = (o as NSString).expandingTildeInPath
        } else {
            let safeName = recipe.name
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "/", with: "_")
            outputPath = "\(safeName).openflix"
        }

        do {
            let data = try bundle.encode()
            try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
            Output.emitDict([
                "exported": true,
                "recipe_id": recipe.id,
                "recipe_name": recipe.name,
                "file_path": outputPath,
                "file_size_bytes": data.count,
            ])
        } catch {
            Output.failMessage("Export failed: \(error.localizedDescription)", code: "export_error")
        }
    }
}

// MARK: - recipe import

struct RecipeImport: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import recipes from a .openflix bundle file or registry URL"
    )

    @Argument(help: "Path to .openflix bundle file")
    var filePath: String?

    @Option(name: .long, help: "Import from registry URL or recipe ID")
    var url: String?

    @Flag(name: .long, help: "Import as fork (sets parentRecipeId)")
    var fork: Bool = false

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        let bundle: RecipeBundle
        if let urlString = url {
            // Import from URL or registry ID
            do {
                if urlString.contains("/") || urlString.hasPrefix("http") {
                    // Full URL — fetch directly
                    bundle = try await RegistryClient.fetchFromURL(urlString)
                } else {
                    // Bare ID — fetch from registry
                    bundle = try await RegistryClient.fetch(recipeId: urlString)
                }
            } catch let error as OpenFlixError {
                Output.fail(error)
            } catch {
                Output.failMessage("Failed to fetch from URL: \(error.localizedDescription)", code: "fetch_failed")
            }
        } else if let fp = filePath {
            // Existing file path logic
            let path = (fp as NSString).expandingTildeInPath
            let fileURL = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else {
                Output.failMessage("File not found: \(fp)", code: "not_found")
            }
            do {
                bundle = try RecipeBundle.decode(fromFile: fileURL)
            } catch {
                Output.failMessage("Failed to read bundle: \(error.localizedDescription)", code: "invalid_input")
            }
        } else {
            Output.failMessage("Provide a file path or --url to import from", code: "invalid_input")
        }

        var imported: [[String: Any]] = []
        for exported in bundle.recipes {
            let recipe = CLIRecipe(from: exported, fork: fork)
            RecipeStore.shared.save(recipe)
            imported.append(recipe.jsonRepresentation)
        }

        if imported.count == 1 {
            Output.emitDict(imported[0])
        } else {
            Output.emitArray(imported)
        }
    }
}

// MARK: - recipe fork

struct RecipeFork: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fork",
        abstract: "Fork an existing recipe with optional overrides"
    )

    @Argument(help: "Recipe ID to fork")
    var recipeId: String

    @Option(name: .long, help: "New recipe name")
    var name: String?

    @Option(name: .long, help: "Override prompt")
    var prompt: String?

    @Option(name: .long, help: "Override negative prompt")
    var negativePrompt: String?

    @Option(name: .long, help: "Override provider")
    var provider: String?

    @Option(name: .long, help: "Override model")
    var model: String?

    @Option(name: .long, help: "Override seed")
    var seed: Int?

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        guard let source = RecipeStore.shared.get(recipeId) else {
            Output.failMessage("Recipe '\(recipeId)' not found.", code: "not_found")
        }

        let forked = CLIRecipe(
            name: name ?? "\(source.name) (fork)",
            promptText: prompt ?? source.promptText,
            negativePromptText: negativePrompt ?? source.negativePromptText,
            provider: provider ?? source.provider,
            model: model ?? source.model,
            aspectRatio: source.aspectRatio,
            durationSeconds: source.durationSeconds,
            widthPx: source.widthPx,
            heightPx: source.heightPx,
            seed: seed ?? source.seed,
            parametersJSON: source.parametersJSON,
            parentRecipeId: source.id,
            forkType: "manual",
            category: source.category
        )

        RecipeStore.shared.save(forked)
        Output.emitDict(forked.jsonRepresentation)
    }
}

// MARK: - recipe run

struct RecipeRun: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a recipe to generate a video"
    )

    @Argument(help: "Recipe ID or path to .openflix file")
    var identifier: String

    @Flag(name: .long, help: "Block until generation completes, then output final JSON")
    var wait: Bool = false

    @Flag(name: .long, help: "Stream newline-delimited JSON progress events to stdout")
    var stream: Bool = false

    @Option(name: .long, help: "Max seconds to wait (default: 300)")
    var timeout: Double = 300

    @Option(name: .long, help: "Poll interval in seconds (default: 3)")
    var pollInterval: Double = 3

    @Option(name: [.short, .long], help: "Output file path for the downloaded video")
    var output: String?

    @Option(name: .long, help: "API key (overrides env var and keychain)")
    var apiKey: String?

    @Flag(name: .long, help: "Skip downloading the video after generation completes")
    var skipDownload: Bool = false

    @Flag(name: .long, help: "Validate request without submitting")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        // Load recipe from store or file
        var recipe: CLIRecipe
        var recipeFromFile = false

        if identifier.hasSuffix(".openflix") {
            let path = (identifier as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else {
                Output.failMessage("File not found: \(identifier)", code: "not_found")
            }
            do {
                let bundle = try RecipeBundle.decode(fromFile: url)
                guard let first = bundle.recipes.first else {
                    Output.failMessage("Bundle contains no recipes.", code: "invalid_input")
                }
                recipe = CLIRecipe(from: first)
                recipeFromFile = true
            } catch {
                Output.failMessage("Failed to read bundle: \(error.localizedDescription)", code: "invalid_input")
            }
        } else {
            guard let found = RecipeStore.shared.get(identifier) else {
                Output.failMessage("Recipe '\(identifier)' not found.", code: "not_found")
            }
            recipe = found
        }

        // Validate provider/model
        guard let providerID = recipe.provider, !providerID.isEmpty else {
            Output.failMessage("Recipe has no provider set. Use: openflix recipe fork \(recipe.id) --provider <provider>", code: "invalid_input")
        }
        guard let modelID = recipe.model, !modelID.isEmpty else {
            Output.failMessage("Recipe has no model set. Use: openflix recipe fork \(recipe.id) --model <model>", code: "invalid_input")
        }

        let registry = ProviderRegistry.shared
        guard let prov = try? registry.provider(for: providerID) else {
            Output.fail(.providerNotFound(providerID))
        }
        let modelInfo = prov.models.first { $0.modelId == modelID }
        if modelInfo == nil {
            Output.failMessage("Model '\(modelID)' not found for provider '\(providerID)'. Run: openflix models --provider \(providerID)", code: "model_not_found")
        }

        // Parse parametersJSON into extras dict
        var extras: [String: Any] = [:]
        if let json = recipe.parametersJSON, let data = json.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            extras = dict
        }

        // Dry run
        if dryRun {
            do { _ = try CLIKeychain.resolveKey(provider: providerID, flagValue: apiKey) }
            catch let e as OpenFlixError { Output.fail(e) }
            catch { Output.failMessage(error.localizedDescription) }
            let est = prov.estimateCost(durationSeconds: recipe.durationSeconds ?? 4, modelId: modelID)
            Output.emitDict([
                "dry_run": true,
                "recipe_id": recipe.id,
                "recipe_name": recipe.name,
                "provider": providerID,
                "model": modelID,
                "prompt": recipe.promptText,
                "duration_seconds": recipe.durationSeconds as Any,
                "aspect_ratio": recipe.aspectRatio as Any,
                "estimated_cost_usd": est as Any,
                "api_key_resolved": true,
            ])
            return
        }

        let opts = GenerationEngine.Options(
            pollInterval: pollInterval,
            timeout: timeout,
            outputURL: output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
            stream: stream,
            skipDownload: skipDownload
        )

        do {
            let gen: CLIGeneration
            if wait || stream {
                gen = try await GenerationEngine.submitAndWait(
                    prompt: recipe.promptText,
                    negativePrompt: recipe.negativePromptText.isEmpty ? nil : recipe.negativePromptText,
                    provider: providerID,
                    model: modelID,
                    durationSeconds: recipe.durationSeconds,
                    aspectRatio: recipe.aspectRatio,
                    width: recipe.widthPx,
                    height: recipe.heightPx,
                    extraParams: extras,
                    apiKey: apiKey,
                    options: opts
                )
            } else {
                gen = try await GenerationEngine.submit(
                    prompt: recipe.promptText,
                    negativePrompt: recipe.negativePromptText.isEmpty ? nil : recipe.negativePromptText,
                    provider: providerID,
                    model: modelID,
                    durationSeconds: recipe.durationSeconds,
                    aspectRatio: recipe.aspectRatio,
                    width: recipe.widthPx,
                    height: recipe.heightPx,
                    extraParams: extras,
                    apiKey: apiKey
                )
            }

            // Update recipe stats
            if !recipeFromFile {
                RecipeStore.shared.update(id: recipe.id) { r in
                    r.generationCount += 1
                    r.generationIds.append(gen.id)
                    if let cost = gen.actualCostUSD ?? gen.estimatedCostUSD {
                        r.totalCostUSD += cost
                    }
                }
            }

            Output.emitDict(gen.jsonRepresentation)
        } catch let error as OpenFlixError {
            Output.fail(error)
        } catch {
            Output.failMessage(error.localizedDescription)
        }
    }
}

// MARK: - recipe publish

struct RecipePublish: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "publish",
        abstract: "Publish a recipe to the OpenFlix registry",
        discussion: """
        Uploads a recipe to the public registry for discovery and forking.

        EXAMPLES
          openflix recipe publish <recipe-id>
          openflix recipe publish <recipe-id> --author "Your Name"
        """
    )

    @Argument(help: "Recipe ID to publish")
    var recipeId: String

    @Option(name: .long, help: "Author name for attribution")
    var author: String?

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty
        guard let recipe = RecipeStore.shared.get(recipeId) else {
            Output.failMessage("Recipe '\(recipeId)' not found", code: "not_found")
        }

        // Build bundle with best execution
        let bestGen: CLIGeneration? = recipe.generationIds
            .compactMap { GenerationStore.shared.get($0) }
            .filter { $0.status == .succeeded }
            .max(by: { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) })

        let exported = recipe.toExported(bestGen: bestGen)
        let bundle = RecipeBundle(exportedAt: Date(), author: author, recipes: [exported])

        do {
            let (id, url) = try await RegistryClient.publish(bundle: bundle, author: author)
            Output.emitDict([
                "id": id,
                "url": url,
                "recipe_name": recipe.name,
                "message": "Published to \(url)",
            ])
        } catch let error as OpenFlixError {
            Output.fail(error)
        } catch {
            Output.failMessage("Failed to publish: \(error.localizedDescription)", code: "publish_failed")
        }
    }
}

// MARK: - recipe search

struct RecipeSearch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search the OpenFlix recipe registry",
        discussion: """
        Search published recipes by name, prompt text, or category.

        EXAMPLES
          openflix recipe search "cinematic sunset"
          openflix recipe search --category cinematic --limit 10
        """
    )

    @Argument(help: "Search query (optional)")
    var query: String?

    @Option(name: .long, help: "Filter by category")
    var category: String?

    @Option(name: .long, help: "Maximum results (default: 20)")
    var limit: Int = 20

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty
        do {
            let results = try await RegistryClient.search(query: query, category: category, limit: limit)
            Output.emitDict(["results": results, "count": results.count])
        } catch let error as OpenFlixError {
            Output.fail(error)
        } catch {
            Output.failMessage("Search failed: \(error.localizedDescription)", code: "search_failed")
        }
    }
}
