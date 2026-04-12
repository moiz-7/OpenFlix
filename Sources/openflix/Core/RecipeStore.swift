import Foundation
import Darwin

// MARK: - CLI Recipe model

struct CLIRecipe: Codable {
    var id: String            // UUID
    var name: String
    var promptText: String
    var negativePromptText: String
    var provider: String?
    var model: String?
    var aspectRatio: String?
    var durationSeconds: Double?
    var widthPx: Int?
    var heightPx: Int?
    var seed: Int?
    var parametersJSON: String?   // JSON dict as string
    var parentRecipeId: String?
    var forkType: String?
    var category: String?
    var generationCount: Int
    var generationIds: [String]
    var avgQualityScore: Double?
    var winCount: Int
    var totalCostUSD: Double
    var createdAt: Date
    var updatedAt: Date

    init(name: String, promptText: String, negativePromptText: String = "",
         provider: String? = nil, model: String? = nil, aspectRatio: String? = nil,
         durationSeconds: Double? = nil, widthPx: Int? = nil, heightPx: Int? = nil,
         seed: Int? = nil, parametersJSON: String? = nil, parentRecipeId: String? = nil,
         forkType: String? = nil, category: String? = nil) {
        self.id = UUID().uuidString
        self.name = name
        self.promptText = promptText
        self.negativePromptText = negativePromptText
        self.provider = provider
        self.model = model
        self.aspectRatio = aspectRatio
        self.durationSeconds = durationSeconds
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.seed = seed
        self.parametersJSON = parametersJSON
        self.parentRecipeId = parentRecipeId
        self.forkType = forkType
        self.category = category
        self.generationCount = 0
        self.generationIds = []
        self.avgQualityScore = nil
        self.winCount = 0
        self.totalCostUSD = 0
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    // Convert to RecipeBundle.ExportedRecipe for export
    func toExported(bestGen: CLIGeneration? = nil) -> RecipeBundle.ExportedRecipe {
        var exported = RecipeBundle.ExportedRecipe(
            id: id, name: name, promptText: promptText,
            negativePromptText: negativePromptText,
            provider: provider, model: model,
            aspectRatio: aspectRatio, durationSeconds: durationSeconds,
            widthPx: widthPx, heightPx: heightPx,
            seed: seed, parentRecipeId: parentRecipeId,
            forkType: forkType, category: category,
            generationCount: generationCount,
            avgQualityScore: avgQualityScore,
            winCount: winCount, totalCostUSD: totalCostUSD
        )
        // Parse parametersJSON to [String: String] if present
        if let json = parametersJSON, let data = json.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            exported.parameters = dict.mapValues { "\($0)" }
        }
        if let gen = bestGen {
            exported.bestExecution = RecipeBundle.ExecutionSnapshot(
                provider: gen.provider, model: gen.model,
                durationSeconds: gen.durationSeconds,
                widthPx: gen.widthPx, heightPx: gen.heightPx,
                costUSD: gen.actualCostUSD ?? gen.estimatedCostUSD,
                completedAt: gen.completedAt
            )
        }
        return exported
    }

    // Create from imported RecipeBundle.ExportedRecipe
    init(from exported: RecipeBundle.ExportedRecipe, fork: Bool = false) {
        self.id = fork ? UUID().uuidString : exported.id
        self.name = fork ? "\(exported.name) (fork)" : exported.name
        self.promptText = exported.promptText
        self.negativePromptText = exported.negativePromptText
        self.provider = exported.provider
        self.model = exported.model
        self.aspectRatio = exported.aspectRatio
        self.durationSeconds = exported.durationSeconds
        self.widthPx = exported.widthPx
        self.heightPx = exported.heightPx
        self.seed = exported.seed
        self.parentRecipeId = fork ? exported.id : exported.parentRecipeId
        self.forkType = fork ? "manual" : exported.forkType
        self.category = exported.category
        self.generationCount = 0
        self.generationIds = []
        self.avgQualityScore = nil
        self.winCount = 0
        self.totalCostUSD = 0
        self.createdAt = Date()
        self.updatedAt = Date()
        // Convert parameters dict to JSON string
        if let params = exported.parameters, !params.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: params) {
            self.parametersJSON = String(data: data, encoding: .utf8)
        } else {
            self.parametersJSON = nil
        }
    }

    // MARK: - JSON output shape (agent-friendly snake_case)

    var jsonRepresentation: [String: Any] {
        var d: [String: Any] = [
            "id": id,
            "name": name,
            "prompt_text": promptText,
            "negative_prompt_text": negativePromptText,
            "generation_count": generationCount,
            "win_count": winCount,
            "total_cost_usd": (totalCostUSD * 10000).rounded() / 10000,
            "generation_ids": generationIds,
            "created_at": ISO8601DateFormatter().string(from: createdAt),
            "updated_at": ISO8601DateFormatter().string(from: updatedAt),
        ]
        if let v = provider        { d["provider"] = v }
        if let v = model           { d["model"] = v }
        if let v = aspectRatio     { d["aspect_ratio"] = v }
        if let v = durationSeconds { d["duration_seconds"] = v }
        if let v = widthPx         { d["width_px"] = v }
        if let v = heightPx        { d["height_px"] = v }
        if let v = seed            { d["seed"] = v }
        if let v = parametersJSON  { d["parameters_json"] = v }
        if let v = parentRecipeId  { d["parent_recipe_id"] = v }
        if let v = forkType        { d["fork_type"] = v }
        if let v = category        { d["category"] = v }
        if let v = avgQualityScore { d["avg_quality_score"] = (v * 10).rounded() / 10 }
        return d
    }
}

// MARK: - Recipe Store

/// JSON-backed persistence for CLI recipes.
/// Stored at ~/.openflix/recipes.json — readable by any agent or script.
final class RecipeStore {
    static let shared = RecipeStore()

    private let storeURL: URL          // ~/.openflix/recipes.json
    private let lockFileURL: URL       // ~/.openflix/recipes.lock
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".openflix", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("recipes.json")
        lockFileURL = dir.appendingPathComponent("recipes.lock")
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - File lock

    private func withFileLock<T>(_ body: () throws -> T) rethrows -> T {
        let fd = open(lockFileURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return try body() }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN); close(fd) }
        return try body()
    }

    // MARK: - CRUD

    func save(_ recipe: CLIRecipe) {
        withFileLock {
            lock.lock(); defer { lock.unlock() }
            var all = loadAll()
            all[recipe.id] = recipe
            persist(all)
        }
    }

    func get(_ id: String) -> CLIRecipe? {
        withFileLock {
            lock.lock(); defer { lock.unlock() }
            return loadAll()[id]
        }
    }

    func all() -> [CLIRecipe] {
        withFileLock {
            lock.lock(); defer { lock.unlock() }
            return Array(loadAll().values).sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    func delete(_ id: String) {
        withFileLock {
            lock.lock(); defer { lock.unlock() }
            var all = loadAll()
            all.removeValue(forKey: id)
            persist(all)
        }
    }

    func update(id: String, mutate: (inout CLIRecipe) -> Void) {
        withFileLock {
            lock.lock(); defer { lock.unlock() }
            var all = loadAll()
            guard var recipe = all[id] else { return }
            mutate(&recipe)
            recipe.updatedAt = Date()
            all[id] = recipe
            persist(all)
        }
    }

    func search(query: String) -> [CLIRecipe] {
        let lowered = query.lowercased()
        return all().filter {
            $0.name.lowercased().contains(lowered) ||
            $0.promptText.lowercased().contains(lowered)
        }
    }

    // MARK: - Private

    private func loadAll() -> [String: CLIRecipe] {
        guard FileManager.default.fileExists(atPath: storeURL.path),
              let data = try? Data(contentsOf: storeURL),
              let map = try? decoder.decode([String: CLIRecipe].self, from: data) else {
            return [:]
        }
        return map
    }

    private func persist(_ map: [String: CLIRecipe]) {
        let data: Data
        do { data = try encoder.encode(map) }
        catch {
            fputs("{\"error\":\"Recipe store encode failed: \(error.localizedDescription)\",\"code\":\"store_error\"}\n", stderr)
            return
        }
        do { try data.write(to: storeURL, options: .atomic) }
        catch {
            fputs("{\"error\":\"Recipe store write failed: \(error.localizedDescription)\",\"code\":\"store_error\"}\n", stderr)
        }
    }
}
