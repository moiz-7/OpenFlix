import XCTest
import OpenFlixKit
@testable import openflix

final class WorkflowRecipeTests: XCTestCase {

    private func makeRecipe(prompt: String = "a {{subject}} at dusk",
                            args: [RecipeArg]? = nil) -> CLIRecipe {
        var recipe = CLIRecipe(
            name: "base", promptText: prompt, negativePromptText: "blurry",
            provider: "fal", model: "fal-ai/veo3",
            aspectRatio: "16:9", durationSeconds: 5
        )
        recipe.parametersJSON = #"{"seed": "42", "camera": "{{subject}} cam"}"#
        recipe.args = args ?? [
            RecipeArg(name: "subject", type: "string", defaultValue: .string("fox"),
                      choices: nil, description: nil)
        ]
        return recipe
    }

    private func stage(recipe: String? = "r1", args: [String: String]? = nil) -> WorkflowStage {
        WorkflowStage(id: "s1", needs: nil, prompt: nil, promptFrom: nil,
                      recipe: recipe, args: args,
                      provider: nil, model: nil, route: nil, category: nil,
                      duration: nil, aspectRatio: nil, negativePrompt: nil,
                      params: nil, fanout: nil, judge: nil)
    }

    // MARK: - Validation (parse-time)

    func testValidationAcceptsRecipeStageWithoutPromptOrProvider() throws {
        let spec = WorkflowSpec(name: "w", budgetUsd: nil, stages: [stage()])
        XCTAssertNoThrow(try WorkflowParser.validate(spec))
    }

    func testValidationRejectsRecipePlusPrompt() {
        var s = stage()
        s.prompt = "conflicting"
        let spec = WorkflowSpec(name: "w", budgetUsd: nil, stages: [s])
        XCTAssertThrowsError(try WorkflowParser.validate(spec)) {
            XCTAssertEqual(($0 as? WorkflowSpecError)?.code, "recipe_conflict")
        }
    }

    func testValidationRejectsArgsWithoutRecipe() {
        var s = stage(recipe: nil, args: ["subject": "owl"])
        s.prompt = "p"; s.provider = "fal"; s.model = "fal-ai/veo3"
        let spec = WorkflowSpec(name: "w", budgetUsd: nil, stages: [s])
        XCTAssertThrowsError(try WorkflowParser.validate(spec)) {
            XCTAssertEqual(($0 as? WorkflowSpecError)?.code, "args_without_recipe")
        }
    }

    // MARK: - Stage-from-recipe resolution

    func testInlinePullsPromptModelParamsFromRecipeWithArgSubstitution() throws {
        let out = try WorkflowRecipeResolver.inline(
            stage: stage(args: ["subject": "owl"]), recipe: makeRecipe())
        XCTAssertEqual(out.prompt, "a owl at dusk")
        XCTAssertEqual(out.negativePrompt, "blurry")
        XCTAssertEqual(out.provider, "fal")
        XCTAssertEqual(out.model, "fal-ai/veo3")
        XCTAssertEqual(out.duration, 5)
        XCTAssertEqual(out.aspectRatio, "16:9")
        XCTAssertEqual(out.params?["seed"], "42")
        XCTAssertEqual(out.params?["camera"], "owl cam")  // substitution reaches params
    }

    func testInlineUsesArgDefaultsWhenStageOmitsValues() throws {
        let out = try WorkflowRecipeResolver.inline(stage: stage(), recipe: makeRecipe())
        XCTAssertEqual(out.prompt, "a fox at dusk")
    }

    func testInlineStageFieldsOverrideRecipeFields() throws {
        var s = stage()
        s.model = "fal-ai/minimax/hailuo-02"
        s.duration = 8
        s.params = ["seed": "7"]
        s.negativePrompt = "grainy"
        let out = try WorkflowRecipeResolver.inline(stage: s, recipe: makeRecipe())
        XCTAssertEqual(out.model, "fal-ai/minimax/hailuo-02")
        XCTAssertEqual(out.provider, "fal")           // still from the recipe
        XCTAssertEqual(out.duration, 8)
        XCTAssertEqual(out.params?["seed"], "7")      // stage wins
        XCTAssertEqual(out.params?["camera"], "fox cam")
        XCTAssertEqual(out.negativePrompt, "grainy")
    }

    func testInlineUnknownRecipeThrowsUnknownRecipe() {
        XCTAssertThrowsError(try WorkflowRecipeResolver.inline(stage: stage(), recipe: nil)) {
            guard case WorkflowSpecError.unknownRecipe(let st, let rid)? = $0 as? WorkflowSpecError else {
                return XCTFail("expected unknownRecipe, got \($0)")
            }
            XCTAssertEqual(st, "s1")
            XCTAssertEqual(rid, "r1")
            XCTAssertEqual(($0 as? WorkflowSpecError)?.code, "unknown_recipe")
        }
    }

    func testInlineMissingRequiredArgSurfacesMissingArg() {
        let recipe = makeRecipe(args: [
            RecipeArg(name: "subject", type: "string", defaultValue: nil,
                      choices: nil, description: nil)
        ])
        XCTAssertThrowsError(try WorkflowRecipeResolver.inline(stage: stage(), recipe: recipe)) {
            XCTAssertEqual(($0 as? RecipeArgError)?.code, "missing_arg")
        }
    }

    func testInlineRecipeWithoutModelAndNoRouteThrowsMissingProvider() {
        var recipe = makeRecipe()
        recipe.provider = nil
        recipe.model = nil
        XCTAssertThrowsError(try WorkflowRecipeResolver.inline(stage: stage(), recipe: recipe)) {
            XCTAssertEqual(($0 as? WorkflowSpecError)?.code, "missing_provider")
        }
        // ...but route: "smart" keeps provider/model open for the router.
        var s = stage()
        s.route = "smart"
        XCTAssertNoThrow(try WorkflowRecipeResolver.inline(stage: s, recipe: recipe))
    }

    func testResolvedPromptsFlowsFromInlinedRecipeStage() throws {
        let inlined = try WorkflowRecipeResolver.inline(stage: stage(), recipe: makeRecipe())
        let downstream = WorkflowStage(
            id: "s2", needs: ["s1"], prompt: nil, promptFrom: "s1",
            recipe: nil, args: nil, provider: "fal", model: "fal-ai/veo3",
            route: nil, category: nil, duration: nil, aspectRatio: nil,
            negativePrompt: nil, params: nil, fanout: nil, judge: nil)
        let spec = WorkflowSpec(name: "w", budgetUsd: nil, stages: [inlined, downstream])
        let prompts = try WorkflowParser.resolvedPrompts(spec)
        XCTAssertEqual(prompts["s2"], "a fox at dusk")
    }

    func testParseDecodesRecipeAndArgsKeys() throws {
        let json = """
        {"name": "w", "stages": [
          {"id": "s1", "recipe": "r1", "args": {"subject": "owl"}}
        ]}
        """
        let spec = try WorkflowParser.parse(data: Data(json.utf8), path: "w.json")
        XCTAssertEqual(spec.stages[0].recipe, "r1")
        XCTAssertEqual(spec.stages[0].args?["subject"], "owl")
    }
}
