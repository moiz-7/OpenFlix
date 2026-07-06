import XCTest
@testable import OpenFlixKit

/// Wave 4: consistency fields (referenceImages / styleLock) in the recipe
/// format. formatVersion stays 3 — these are optional extensions valid in
/// any v3 bundle; v2 bundles and v3 bundles without them decode with nil.
final class StyleLockTests: XCTestCase {

    // MARK: - Codable roundtrip

    func testExportedRecipeRoundtripsReferenceImagesAndStyleLock() throws {
        let recipe = RecipeBundle.ExportedRecipe(
            id: "aaaa", name: "Locked Look",
            promptText: "ceramic robot barista", negativePromptText: "",
            referenceImages: ["refs/robot-front.png", "https://example.com/robot-side.png"],
            styleLock: StyleLock(seedPolicy: .fixed, notes: "keep the glaze identical")
        )
        let bundle = RecipeBundle(
            formatVersion: RecipeBundle.formatVersion(for: [recipe]),
            exportedAt: Date(timeIntervalSince1970: 1_751_000_000), recipes: [recipe])

        XCTAssertEqual(bundle.formatVersion, 3, "consistency fields are a v3 feature")

        let decoded = try RecipeBundle.decode(from: bundle.encode())
        let r = try XCTUnwrap(decoded.recipes.first)
        XCTAssertEqual(r.referenceImages, ["refs/robot-front.png", "https://example.com/robot-side.png"])
        XCTAssertEqual(r.styleLock?.seedPolicy, .fixed)
        XCTAssertEqual(r.styleLock?.notes, "keep the glaze identical")
    }

    func testSeedPolicyRawValuesAndPerShotRoundtrip() throws {
        XCTAssertEqual(SeedPolicy.fixed.rawValue, "fixed")
        XCTAssertEqual(SeedPolicy.perShot.rawValue, "per_shot")

        let data = try JSONEncoder().encode(StyleLock(seedPolicy: .perShot))
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains(#""seedPolicy":"per_shot""#), "got: \(json)")
        let decoded = try JSONDecoder().decode(StyleLock.self, from: data)
        XCTAssertEqual(decoded.seedPolicy, .perShot)
        XCTAssertNil(decoded.notes)
    }

    // MARK: - Backward compatibility

    func testV2BundleWithoutConsistencyFieldsDecodesNil() throws {
        let json = """
        {"formatVersion": 2, "exportedAt": "2026-01-01T00:00:00Z",
         "recipes": [{"id": "x", "name": "old", "promptText": "p", "negativePromptText": ""}]}
        """
        let decoded = try RecipeBundle.decode(from: Data(json.utf8))
        let r = try XCTUnwrap(decoded.recipes.first)
        XCTAssertNil(r.referenceImages)
        XCTAssertNil(r.styleLock)
    }

    func testV3BundleWithArgsButWithoutConsistencyFieldsDecodesNil() throws {
        let json = """
        {"formatVersion": 3, "exportedAt": "2026-01-01T00:00:00Z",
         "recipes": [{"id": "x", "name": "v3", "promptText": "a {{subject}}", "negativePromptText": "",
                      "args": [{"name": "subject", "type": "string"}]}]}
        """
        let decoded = try RecipeBundle.decode(from: Data(json.utf8))
        let r = try XCTUnwrap(decoded.recipes.first)
        XCTAssertEqual(r.args?.count, 1)
        XCTAssertNil(r.referenceImages)
        XCTAssertNil(r.styleLock)
    }

    func testFormatVersionStaysTwoWithoutV3Features() {
        let plain = RecipeBundle.ExportedRecipe(
            id: "y", name: "plain", promptText: "p", negativePromptText: "")
        XCTAssertEqual(RecipeBundle.formatVersion(for: [plain]), 2)
        var locked = plain
        locked.styleLock = StyleLock(seedPolicy: .perShot)
        XCTAssertEqual(RecipeBundle.formatVersion(for: [locked]), 3)
    }

    // MARK: - Recipe <-> ExportedRecipe carry (app/CLI round-trip via the kit)

    func testRecipeExportImportCarriesConsistencyFields() {
        var recipe = Recipe(name: "carry", promptText: "p")
        recipe.referenceImages = ["ref.png"]
        recipe.styleLock = StyleLock(seedPolicy: .fixed, notes: "n")

        let exported = recipe.toExported()
        XCTAssertEqual(exported.referenceImages, ["ref.png"])
        XCTAssertEqual(exported.styleLock?.seedPolicy, .fixed)

        let imported = Recipe(from: exported)
        XCTAssertEqual(imported.referenceImages, ["ref.png"])
        XCTAssertEqual(imported.styleLock?.seedPolicy, .fixed)
        XCTAssertEqual(imported.styleLock?.notes, "n")

        let json = imported.jsonRepresentation
        XCTAssertEqual(json["reference_images"] as? [String], ["ref.png"])
        XCTAssertEqual((json["style_lock"] as? [String: Any])?["seed_policy"] as? String, "fixed")
    }
}
