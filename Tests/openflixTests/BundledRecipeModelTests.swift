import XCTest
import OpenFlixKit
@testable import openflix

/// Every recipe this repo ships must run. The catalog retires model ids when
/// a provider stops serving them; a bundled recipe still naming one would be
/// refused the first time a user ran it. Nothing here reaches a network.
final class BundledRecipeModelTests: XCTestCase {

    private var recipesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // openflixTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("recipes")
    }

    func testEveryBundledRecipeNamesALiveModelAndAValidDuration() throws {
        let files = try FileManager.default.contentsOfDirectory(at: recipesDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "openflix" }
        XCTAssertFalse(files.isEmpty, "no bundled recipes found — the test would pass vacuously")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for file in files {
            let bundle = try decoder.decode(RecipeBundle.self, from: Data(contentsOf: file))
            for recipe in bundle.recipes {
                guard let provider = recipe.provider, let model = recipe.model else { continue }
                let label = "\(file.lastPathComponent): \(provider) \(model)"
                XCTAssertNil(VideoModelCatalog.retiredRefusal(model: model), label)
                XCTAssertNoThrow(try GenerationEngine.validateModel(providerID: provider, model: model, hasImage: false), label)
                let info = ProviderRegistry.shared.allModels.first { $0.providerId == provider && $0.modelId == model }
                XCTAssertNoThrow(try GenerationEngine.validateDuration(recipe.durationSeconds, providerID: provider,
                                                                      model: model, modelInfo: info), label)
            }
        }
    }
}
