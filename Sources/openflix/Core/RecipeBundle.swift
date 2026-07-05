import Foundation

/// Portable .openflix recipe bundle format (JSON).
/// Used for export/import/sharing between app, CLI, and GitHub.
struct RecipeBundle: Codable {
    var formatVersion: Int = 2
    var exportedAt: Date
    var author: String?
    var recipes: [ExportedRecipe]

    /// v3 is only written when a recipe actually uses v3 features (args/uses);
    /// otherwise stay at 2 so existing exported files don't churn.
    static func formatVersion(for recipes: [ExportedRecipe]) -> Int {
        let usesV3 = recipes.contains {
            !($0.args ?? []).isEmpty || !($0.uses ?? []).isEmpty
        }
        return usesV3 ? 3 : 2
    }

    struct ExportedRecipe: Codable {
        var id: String                    // UUID, stable across exports
        var name: String
        var promptText: String
        var negativePromptText: String
        var enhancedPromptText: String?
        var provider: String?
        var model: String?
        var aspectRatio: String?
        var durationSeconds: Double?
        var widthPx: Int?
        var heightPx: Int?
        var parameters: [String: String]?
        var referenceImagePaths: [String]?
        var seed: Int?
        var parentRecipeId: String?
        var forkType: String?
        var category: String?
        var generationCount: Int?
        var avgQualityScore: Double?
        var winCount: Int?
        var totalCostUSD: Double?
        var bestExecution: ExecutionSnapshot?
        var args: [RecipeArg]?        // formatVersion 3: declared arguments
        var uses: [RecipeUse]?        // formatVersion 3: composition references
    }

    struct ExecutionSnapshot: Codable {
        var provider: String
        var model: String
        var qualityScore: Double?
        var durationSeconds: Double?
        var widthPx: Int?
        var heightPx: Int?
        var costUSD: Double?
        var completedAt: Date?
    }

    func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(from data: Data) throws -> RecipeBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecipeBundle.self, from: data)
    }

    static func decode(fromFile url: URL) throws -> RecipeBundle {
        let data = try Data(contentsOf: url)
        return try decode(from: data)
    }
}
