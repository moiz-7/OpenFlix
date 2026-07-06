import XCTest
import OpenFlixKit
@testable import openflix

/// Wave 4: reference_from (upstream output fed forward as the I2V reference),
/// consistency intent carried from recipes, and the styleLock seed policy.
final class WorkflowReferenceTests: XCTestCase {

    private func parse(_ json: String) throws -> WorkflowSpec {
        try WorkflowParser.parse(data: Data(json.utf8), path: "wf.json")
    }

    // MARK: - reference_from validation + normalization

    func testReferenceFromIsAddedToNeeds() throws {
        let spec = try parse("""
        {"name": "w", "stages": [
          {"id": "shot1", "prompt": "a", "provider": "fal", "model": "fal-ai/veo3"},
          {"id": "shot2", "reference_from": "shot1", "prompt": "b",
           "provider": "kling", "model": "kling-v2.6-pro"}]}
        """)
        XCTAssertEqual(spec.stages[1].needs, ["shot1"],
                       "reference_from implies a DAG edge")
    }

    func testReferenceFromAlreadyInNeedsIsNotDuplicated() throws {
        let spec = try parse("""
        {"name": "w", "stages": [
          {"id": "shot1", "prompt": "a", "provider": "fal", "model": "fal-ai/veo3"},
          {"id": "shot2", "needs": ["shot1"], "reference_from": "shot1", "prompt": "b",
           "provider": "kling", "model": "kling-v2.6-pro"}]}
        """)
        XCTAssertEqual(spec.stages[1].needs, ["shot1"])
    }

    func testUnknownReferenceFromIsStructuredError() {
        XCTAssertThrowsError(try parse("""
        {"name": "w", "stages": [
          {"id": "shot1", "reference_from": "ghost", "prompt": "a",
           "provider": "fal", "model": "fal-ai/veo3"}]}
        """)) {
            XCTAssertEqual(($0 as? WorkflowSpecError)?.code, "unknown_reference")
        }
    }

    func testSelfReferenceIsStructuredError() {
        XCTAssertThrowsError(try parse("""
        {"name": "w", "stages": [
          {"id": "shot1", "reference_from": "shot1", "prompt": "a",
           "provider": "fal", "model": "fal-ai/veo3"}]}
        """)) {
            XCTAssertEqual(($0 as? WorkflowSpecError)?.code, "unknown_reference")
        }
    }

    func testReferenceFromCycleIsRejected() {
        // a needs b explicitly; b references a → edge b→a closes the loop.
        XCTAssertThrowsError(try parse("""
        {"name": "w", "stages": [
          {"id": "a", "needs": ["b"], "prompt": "x", "provider": "fal", "model": "fal-ai/veo3"},
          {"id": "b", "reference_from": "a", "prompt": "y", "provider": "fal", "model": "fal-ai/veo3"}]}
        """)) {
            XCTAssertEqual(($0 as? WorkflowSpecError)?.code, "cyclic_dependency")
        }
    }

    func testStageDecodesConsistencyFields() throws {
        let spec = try parse("""
        {"name": "w", "stages": [
          {"id": "s", "prompt": "a", "provider": "fal", "model": "fal-ai/veo3",
           "reference_images": ["ref.png"],
           "style_lock": {"seedPolicy": "fixed", "notes": "hold the look"}}]}
        """)
        XCTAssertEqual(spec.stages[0].referenceImages, ["ref.png"])
        XCTAssertEqual(spec.stages[0].styleLock?.seedPolicy, .fixed)
        XCTAssertEqual(spec.stages[0].styleLock?.notes, "hold the look")
    }

    // MARK: - Seed policy (pure)

    func testFixedPolicyInjectsDeterministicSeed() {
        let a = StyleLockSeed.apply(params: nil,
                                    styleLock: StyleLock(seedPolicy: .fixed),
                                    seedSource: "film|shot1")
        let b = StyleLockSeed.apply(params: [:],
                                    styleLock: StyleLock(seedPolicy: .fixed),
                                    seedSource: "film|shot1")
        XCTAssertNotNil(a?["seed"])
        XCTAssertEqual(a?["seed"], b?["seed"], "same source → same seed (reproducible)")
        let other = StyleLockSeed.apply(params: nil,
                                        styleLock: StyleLock(seedPolicy: .fixed),
                                        seedSource: "film|shot2")
        XCTAssertNotEqual(a?["seed"], other?["seed"], "different stage → different seed")
        // Seed must be a valid provider seed (non-negative int)
        XCTAssertGreaterThanOrEqual(Int(a?["seed"] ?? "") ?? -1, 0)
    }

    func testFixedPolicyKeepsExplicitSeed() {
        let out = StyleLockSeed.apply(params: ["seed": "42"],
                                      styleLock: StyleLock(seedPolicy: .fixed),
                                      seedSource: "film|shot1")
        XCTAssertEqual(out?["seed"], "42", "an explicit seed always wins")
    }

    func testPerShotAndNoStyleLockLeaveParamsUntouched() {
        XCTAssertNil(StyleLockSeed.apply(params: nil,
                                         styleLock: StyleLock(seedPolicy: .perShot),
                                         seedSource: "s"))
        XCTAssertNil(StyleLockSeed.apply(params: nil, styleLock: nil, seedSource: "s"))
        let untouched = StyleLockSeed.apply(params: ["audio": "true"],
                                            styleLock: StyleLock(seedPolicy: .perShot),
                                            seedSource: "s")
        XCTAssertEqual(untouched, ["audio": "true"])
    }

    // MARK: - Recipe-backed stages carry consistency intent

    private func lockedRecipe() -> CLIRecipe {
        var recipe = CLIRecipe(
            name: "locked", promptText: "robot barista", negativePromptText: "",
            provider: "kling", model: "kling-v2.6-pro", durationSeconds: 5, seed: 777)
        recipe.referenceImages = ["refs/robot.png"]
        recipe.styleLock = StyleLock(seedPolicy: .fixed, notes: "glaze")
        return recipe
    }

    private func recipeStage() -> WorkflowStage {
        WorkflowStage(id: "s1", needs: nil, prompt: nil, promptFrom: nil,
                      recipe: "r1", args: nil,
                      provider: nil, model: nil, route: nil, category: nil,
                      duration: nil, aspectRatio: nil, negativePrompt: nil,
                      params: nil, fanout: nil, judge: nil,
                      referenceFrom: nil, referenceImages: nil, styleLock: nil)
    }

    func testInlineCarriesReferenceImagesAndStyleLockFromRecipe() throws {
        let out = try WorkflowRecipeResolver.inline(stage: recipeStage(), recipe: lockedRecipe())
        XCTAssertEqual(out.referenceImages, ["refs/robot.png"])
        XCTAssertEqual(out.styleLock?.seedPolicy, .fixed)
        XCTAssertEqual(out.params?["seed"], "777",
                       "fixed policy pins the recipe's seed into stage params")
    }

    func testInlineStageFieldsOverrideRecipeConsistencyIntent() throws {
        var stage = recipeStage()
        stage.referenceImages = ["mine.png"]
        stage.styleLock = StyleLock(seedPolicy: .perShot)
        let out = try WorkflowRecipeResolver.inline(stage: stage, recipe: lockedRecipe())
        XCTAssertEqual(out.referenceImages, ["mine.png"])
        XCTAssertEqual(out.styleLock?.seedPolicy, .perShot)
        XCTAssertNil(out.params?["seed"], "per_shot does not pin the recipe seed")
    }
}
