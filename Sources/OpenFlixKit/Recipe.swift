import Foundation

// MARK: - Recipe model
//
// The canonical .openflix recipe record (known as `CLIRecipe` inside the CLI
// via a typealias). Pure Codable + Foundation — persistence (RecipeStore,
// GRDB, …) is a consumer decision and stays out of the kit.

public struct Recipe: Codable {
    public var id: String            // UUID
    public var name: String
    public var promptText: String
    public var negativePromptText: String
    public var provider: String?
    public var model: String?
    public var aspectRatio: String?
    public var durationSeconds: Double?
    public var widthPx: Int?
    public var heightPx: Int?
    public var seed: Int?
    public var parametersJSON: String?   // JSON dict as string
    public var parentRecipeId: String?
    public var forkType: String?
    public var category: String?
    public var generationCount: Int
    public var generationIds: [String]
    public var avgQualityScore: Double?
    public var winCount: Int
    public var totalCostUSD: Double
    public var createdAt: Date
    public var updatedAt: Date
    public var args: [RecipeArg]?    // formatVersion 3: declared arguments (optional — v2 recipes decode as nil)
    public var uses: [RecipeUse]?    // formatVersion 3: composition references
    public var referenceImages: [String]?  // formatVersion 3: consistency intent — reference image paths or URLs
    public var styleLock: StyleLock?       // formatVersion 3: consistency intent — seed policy + notes

    public init(name: String, promptText: String, negativePromptText: String = "",
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
        self.args = nil
        self.uses = nil
        self.referenceImages = nil
        self.styleLock = nil
    }

    // Convert to RecipeBundle.ExportedRecipe for export. Consumers that track
    // executions (e.g. the CLI's generation store) attach `bestExecution`
    // after the fact.
    public func toExported() -> RecipeBundle.ExportedRecipe {
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
        let params = parameterStrings()
        if !params.isEmpty { exported.parameters = params }
        exported.args = args
        exported.uses = uses
        exported.referenceImages = referenceImages
        exported.styleLock = styleLock
        return exported
    }

    // Create from imported RecipeBundle.ExportedRecipe
    public init(from exported: RecipeBundle.ExportedRecipe, fork: Bool = false) {
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
        self.args = exported.args
        self.uses = exported.uses
        self.referenceImages = exported.referenceImages
        self.styleLock = exported.styleLock
        // Convert parameters dict to JSON string
        if let params = exported.parameters, !params.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: params) {
            self.parametersJSON = String(data: data, encoding: .utf8)
        } else {
            self.parametersJSON = nil
        }
    }

    // MARK: - JSON output shape (agent-friendly snake_case)

    public var jsonRepresentation: [String: Any] {
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
        if let v = args, !v.isEmpty, let json = Self.encodeAsJSONObject(v) { d["args"] = json }
        if let v = uses, !v.isEmpty, let json = Self.encodeAsJSONObject(v) { d["uses"] = json }
        if let v = referenceImages, !v.isEmpty { d["reference_images"] = v }
        if let v = styleLock {
            var sl: [String: Any] = ["seed_policy": v.seedPolicy.rawValue]
            if let n = v.notes { sl["notes"] = n }
            d["style_lock"] = sl
        }
        return d
    }

    private static func encodeAsJSONObject<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
