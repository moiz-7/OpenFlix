import XCTest
@testable import openflix

final class WorkflowSpecTests: XCTestCase {

    private func parse(_ json: String, path: String = "wf.json") throws -> WorkflowSpec {
        try WorkflowParser.parse(data: Data(json.utf8), path: path)
    }

    // MARK: - Parsing

    func testParsesValidWorkflow() throws {
        let json = """
        {
          "name": "film",
          "budget_usd": 3.5,
          "stages": [
            {"id": "a", "prompt": "wide shot", "provider": "fal", "model": "fal-ai/veo3", "duration": 5},
            {"id": "b", "needs": ["a"], "prompt_from": "a", "provider": "fal", "model": "fal-ai/veo3",
             "fanout": 4, "judge": {"keep": 1, "min_score": 60}}
          ]
        }
        """
        let spec = try parse(json)
        XCTAssertEqual(spec.name, "film")
        XCTAssertEqual(spec.budgetUsd ?? 0, 3.5, accuracy: 0.001)
        XCTAssertEqual(spec.stages.count, 2)
        XCTAssertEqual(spec.stages[1].needs, ["a"])
        XCTAssertEqual(spec.stages[1].fanout, 4)
        XCTAssertEqual(spec.stages[1].judge?.keep, 1)
        XCTAssertEqual(spec.stages[1].judge?.minScore ?? 0, 60, accuracy: 0.001)

        // prompt_from resolves to the upstream prompt
        let prompts = try WorkflowParser.resolvedPrompts(spec)
        XCTAssertEqual(prompts["b"], "wide shot")
    }

    func testRejectsYAMLFiles() {
        XCTAssertThrowsError(try parse("name: x", path: "wf.yaml")) { error in
            XCTAssertEqual((error as? WorkflowSpecError)?.code, "yaml_not_supported")
        }
    }

    func testRejectsInvalidJSON() {
        XCTAssertThrowsError(try parse("{not json")) { error in
            XCTAssertEqual((error as? WorkflowSpecError)?.code, "invalid_workflow_file")
        }
    }

    // MARK: - Validation

    func testRejectsDuplicateStageIds() {
        let json = """
        {"name": "x", "stages": [
          {"id": "a", "prompt": "p", "provider": "fal", "model": "m"},
          {"id": "a", "prompt": "p", "provider": "fal", "model": "m"}
        ]}
        """
        XCTAssertThrowsError(try parse(json)) { error in
            XCTAssertEqual((error as? WorkflowSpecError)?.code, "duplicate_stage_id")
        }
    }

    func testRejectsUnknownDependency() {
        let json = """
        {"name": "x", "stages": [
          {"id": "a", "needs": ["ghost"], "prompt": "p", "provider": "fal", "model": "m"}
        ]}
        """
        XCTAssertThrowsError(try parse(json)) { error in
            XCTAssertEqual((error as? WorkflowSpecError)?.code, "unknown_dependency")
        }
    }

    func testRejectsCycle() {
        let json = """
        {"name": "x", "stages": [
          {"id": "a", "needs": ["b"], "prompt": "p", "provider": "fal", "model": "m"},
          {"id": "b", "needs": ["a"], "prompt": "p", "provider": "fal", "model": "m"}
        ]}
        """
        XCTAssertThrowsError(try parse(json)) { error in
            XCTAssertEqual((error as? WorkflowSpecError)?.code, "cyclic_dependency")
        }
    }

    func testRejectsMissingPromptAndProvider() {
        let noPrompt = """
        {"name": "x", "stages": [{"id": "a", "provider": "fal", "model": "m"}]}
        """
        XCTAssertThrowsError(try parse(noPrompt)) { error in
            XCTAssertEqual((error as? WorkflowSpecError)?.code, "missing_prompt")
        }
        let noProvider = """
        {"name": "x", "stages": [{"id": "a", "prompt": "p"}]}
        """
        XCTAssertThrowsError(try parse(noProvider)) { error in
            XCTAssertEqual((error as? WorkflowSpecError)?.code, "missing_provider")
        }
    }

    func testRejectsInvalidFanoutAndJudge() {
        let badFanout = """
        {"name": "x", "stages": [{"id": "a", "prompt": "p", "provider": "f", "model": "m", "fanout": 0}]}
        """
        XCTAssertThrowsError(try parse(badFanout)) { error in
            XCTAssertEqual((error as? WorkflowSpecError)?.code, "invalid_fanout")
        }
        let badJudge = """
        {"name": "x", "stages": [{"id": "a", "prompt": "p", "provider": "f", "model": "m",
          "judge": {"keep": 0}}]}
        """
        XCTAssertThrowsError(try parse(badJudge)) { error in
            XCTAssertEqual((error as? WorkflowSpecError)?.code, "invalid_judge")
        }
    }

    // MARK: - Budget gate math

    func testBudgetGateProceedsWithoutLimit() {
        XCTAssertEqual(WorkflowBudgetGate.check(estimatedTotalUSD: 100, limitUSD: nil, approved: false), .proceed)
    }

    func testBudgetGateRequiresApprovalOverLimit() {
        let decision = WorkflowBudgetGate.check(estimatedTotalUSD: 5.01, limitUSD: 5.0, approved: false)
        XCTAssertEqual(decision, .approvalRequired(estimate: 5.01, limit: 5.0))
    }

    func testBudgetGateProceedsUnderLimitOrWithApproval() {
        XCTAssertEqual(WorkflowBudgetGate.check(estimatedTotalUSD: 4.99, limitUSD: 5.0, approved: false), .proceed)
        XCTAssertEqual(WorkflowBudgetGate.check(estimatedTotalUSD: 5.0, limitUSD: 5.0, approved: false), .proceed)
        XCTAssertEqual(WorkflowBudgetGate.check(estimatedTotalUSD: 99, limitUSD: 5.0, approved: true), .proceed)
    }

    func testCostEstimateMath() {
        // cps 0.10 × 5s × fanout 4 = 2.0
        XCTAssertEqual(WorkflowCost.estimate(costPerSecondUSD: 0.10, duration: 5, fanout: 4) ?? 0, 2.0, accuracy: 0.0001)
        // default duration 4s
        XCTAssertEqual(WorkflowCost.estimate(costPerSecondUSD: 0.10, duration: nil, fanout: 1) ?? 0, 0.4, accuracy: 0.0001)
        // unknown cost table → nil
        XCTAssertNil(WorkflowCost.estimate(costPerSecondUSD: nil, duration: 5, fanout: 2))
    }

    // MARK: - Judge keep-K selection (pure)

    private func c(_ id: String, _ score: Double?) -> JudgeSelector.Candidate {
        JudgeSelector.Candidate(id: id, score: score)
    }

    func testJudgeKeepsTopKByScore() {
        let kept = JudgeSelector.selectTopK(
            [c("a", 50), c("b", 90), c("c", 70), c("d", 80)], keep: 2, minScore: nil)
        XCTAssertEqual(kept.map { $0.id }, ["b", "d"])
    }

    func testJudgeAppliesMinScoreFilter() {
        let kept = JudgeSelector.selectTopK(
            [c("a", 50), c("b", 90), c("c", 70)], keep: 3, minScore: 60)
        XCTAssertEqual(kept.map { $0.id }, ["b", "c"])
    }

    func testJudgeReturnsEmptyWhenNothingMeetsMinScore() {
        let kept = JudgeSelector.selectTopK([c("a", 10), c("b", 20)], keep: 1, minScore: 60)
        XCTAssertTrue(kept.isEmpty)
    }

    func testJudgeFallsBackToFirstKWhenNothingScored() {
        // Evaluator unavailable — can't judge, keep the first K unfiltered.
        let kept = JudgeSelector.selectTopK([c("a", nil), c("b", nil), c("c", nil)], keep: 2, minScore: 60)
        XCTAssertEqual(kept.map { $0.id }, ["a", "b"])
    }

    func testJudgeIgnoresUnscoredWhenSomeAreScored() {
        let kept = JudgeSelector.selectTopK([c("a", nil), c("b", 75)], keep: 2, minScore: nil)
        XCTAssertEqual(kept.map { $0.id }, ["b"])
    }

    func testJudgeKeepLargerThanPool() {
        let kept = JudgeSelector.selectTopK([c("a", 80)], keep: 5, minScore: nil)
        XCTAssertEqual(kept.map { $0.id }, ["a"])
    }
}
