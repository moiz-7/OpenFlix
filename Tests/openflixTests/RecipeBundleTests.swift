import XCTest
@testable import openflix

final class RecipeBundleTests: XCTestCase {

    func testCodableRoundtripPreservesFields() throws {
        let recipe = RecipeBundle.ExportedRecipe(
            id: "11111111-2222-3333-4444-555555555555",
            name: "Cinematic Sunset",
            promptText: "golden hour over the ocean, anamorphic",
            negativePromptText: "blurry, low quality",
            enhancedPromptText: nil,
            provider: "fal",
            model: "fal-ai/veo3",
            aspectRatio: "16:9",
            durationSeconds: 8,
            widthPx: 1280,
            heightPx: 720,
            parameters: ["seed": "42"],
            referenceImagePaths: nil,
            seed: 42,
            parentRecipeId: nil,
            forkType: nil,
            category: "cinematic",
            generationCount: 3,
            avgQualityScore: 8.5,
            winCount: 2,
            totalCostUSD: 1.2,
            bestExecution: RecipeBundle.ExecutionSnapshot(
                provider: "fal", model: "fal-ai/veo3",
                qualityScore: 9.1, durationSeconds: 8,
                widthPx: 1280, heightPx: 720,
                costUSD: 0.4, completedAt: Date(timeIntervalSince1970: 1_750_000_000)
            )
        )
        let bundle = RecipeBundle(exportedAt: Date(timeIntervalSince1970: 1_751_000_000),
                                  author: "tester", recipes: [recipe])

        let data = try bundle.encode()
        let decoded = try RecipeBundle.decode(from: data)

        XCTAssertEqual(decoded.formatVersion, 2)
        XCTAssertEqual(decoded.author, "tester")
        XCTAssertEqual(decoded.recipes.count, 1)

        let r = try XCTUnwrap(decoded.recipes.first)
        XCTAssertEqual(r.id, recipe.id)
        XCTAssertEqual(r.name, "Cinematic Sunset")
        XCTAssertEqual(r.promptText, recipe.promptText)
        XCTAssertEqual(r.negativePromptText, recipe.negativePromptText)
        XCTAssertEqual(r.provider, "fal")
        XCTAssertEqual(r.model, "fal-ai/veo3")
        XCTAssertEqual(r.parameters?["seed"], "42")
        XCTAssertEqual(r.seed, 42)
        XCTAssertEqual(r.avgQualityScore ?? 0, 8.5, accuracy: 0.0001)

        let exec = try XCTUnwrap(r.bestExecution)
        XCTAssertEqual(exec.provider, "fal")
        XCTAssertEqual(exec.qualityScore ?? 0, 9.1, accuracy: 0.0001)
        XCTAssertEqual(exec.completedAt, Date(timeIntervalSince1970: 1_750_000_000))
    }

    func testDefaultFormatVersionIsTwo() {
        let bundle = RecipeBundle(exportedAt: Date(), author: nil, recipes: [])
        XCTAssertEqual(bundle.formatVersion, 2)
    }

    func testRegistryTokenResolutionPrefersFlag() {
        XCTAssertEqual(RegistryClient.resolveToken(flagValue: "flag-token"), "flag-token")
        // Empty flag is treated as absent — never returns an empty string
        XCTAssertNotEqual(RegistryClient.resolveToken(flagValue: ""), "")
    }
}
