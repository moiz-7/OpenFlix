import Foundation

/// Portable .openflix recipe bundle format (JSON).
/// Used for export/import/sharing between app, CLI, and GitHub.
public struct RecipeBundle: Codable {
    public var formatVersion: Int = 2
    public var exportedAt: Date
    public var author: String?
    public var recipes: [ExportedRecipe]

    public init(formatVersion: Int = 2, exportedAt: Date,
                author: String? = nil, recipes: [ExportedRecipe]) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.author = author
        self.recipes = recipes
    }

    /// v3 is only written when a recipe actually uses v3 features
    /// (args/uses/referenceImages/styleLock); otherwise stay at 2 so existing
    /// exported files don't churn. Note: 3 means "has optional extensions" —
    /// referenceImages/styleLock are valid in any v3 bundle (there is no 3.1).
    public static func formatVersion(for recipes: [ExportedRecipe]) -> Int {
        let usesV3 = recipes.contains {
            !($0.args ?? []).isEmpty || !($0.uses ?? []).isEmpty
                || !($0.referenceImages ?? []).isEmpty || $0.styleLock != nil
        }
        return usesV3 ? 3 : 2
    }

    public struct ExportedRecipe: Codable {
        public var id: String                    // UUID, stable across exports
        public var name: String
        public var promptText: String
        public var negativePromptText: String
        public var enhancedPromptText: String?
        public var provider: String?
        public var model: String?
        public var aspectRatio: String?
        public var durationSeconds: Double?
        public var widthPx: Int?
        public var heightPx: Int?
        public var parameters: [String: String]?
        public var referenceImagePaths: [String]?
        public var seed: Int?
        public var parentRecipeId: String?
        public var forkType: String?
        public var category: String?
        public var generationCount: Int?
        public var avgQualityScore: Double?
        public var winCount: Int?
        public var totalCostUSD: Double?
        public var bestExecution: ExecutionSnapshot?
        public var args: [RecipeArg]?        // formatVersion 3: declared arguments
        public var uses: [RecipeUse]?        // formatVersion 3: composition references
        public var referenceImages: [String]?  // formatVersion 3: consistency intent — reference image paths or URLs
        public var styleLock: StyleLock?       // formatVersion 3: consistency intent — seed policy + notes

        public init(id: String, name: String, promptText: String,
                    negativePromptText: String,
                    enhancedPromptText: String? = nil,
                    provider: String? = nil, model: String? = nil,
                    aspectRatio: String? = nil, durationSeconds: Double? = nil,
                    widthPx: Int? = nil, heightPx: Int? = nil,
                    parameters: [String: String]? = nil,
                    referenceImagePaths: [String]? = nil,
                    seed: Int? = nil, parentRecipeId: String? = nil,
                    forkType: String? = nil, category: String? = nil,
                    generationCount: Int? = nil, avgQualityScore: Double? = nil,
                    winCount: Int? = nil, totalCostUSD: Double? = nil,
                    bestExecution: ExecutionSnapshot? = nil,
                    args: [RecipeArg]? = nil, uses: [RecipeUse]? = nil,
                    referenceImages: [String]? = nil, styleLock: StyleLock? = nil) {
            self.id = id
            self.name = name
            self.promptText = promptText
            self.negativePromptText = negativePromptText
            self.enhancedPromptText = enhancedPromptText
            self.provider = provider
            self.model = model
            self.aspectRatio = aspectRatio
            self.durationSeconds = durationSeconds
            self.widthPx = widthPx
            self.heightPx = heightPx
            self.parameters = parameters
            self.referenceImagePaths = referenceImagePaths
            self.seed = seed
            self.parentRecipeId = parentRecipeId
            self.forkType = forkType
            self.category = category
            self.generationCount = generationCount
            self.avgQualityScore = avgQualityScore
            self.winCount = winCount
            self.totalCostUSD = totalCostUSD
            self.bestExecution = bestExecution
            self.args = args
            self.uses = uses
            self.referenceImages = referenceImages
            self.styleLock = styleLock
        }
    }

    public struct ExecutionSnapshot: Codable {
        public var provider: String
        public var model: String
        public var qualityScore: Double?
        public var durationSeconds: Double?
        public var widthPx: Int?
        public var heightPx: Int?
        public var costUSD: Double?
        public var completedAt: Date?

        public init(provider: String, model: String,
                    qualityScore: Double? = nil, durationSeconds: Double? = nil,
                    widthPx: Int? = nil, heightPx: Int? = nil,
                    costUSD: Double? = nil, completedAt: Date? = nil) {
            self.provider = provider
            self.model = model
            self.qualityScore = qualityScore
            self.durationSeconds = durationSeconds
            self.widthPx = widthPx
            self.heightPx = heightPx
            self.costUSD = costUSD
            self.completedAt = completedAt
        }
    }

    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(from data: Data) throws -> RecipeBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecipeBundle.self, from: data)
    }

    public static func decode(fromFile url: URL) throws -> RecipeBundle {
        let data = try Data(contentsOf: url)
        return try decode(from: data)
    }
}
