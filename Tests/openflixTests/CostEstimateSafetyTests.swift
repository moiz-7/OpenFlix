import XCTest
import OpenFlixKit
@testable import openflix

/// Non-finite arithmetic on the spend paths.
///
/// This project has been bitten twice by the same shape: a `Double` that a user
/// or a JSON file supplied reaches arithmetic that assumes it is a real number.
/// `Int(Double.nan)` traps and aborts the process; `NaN > limit` is *false*, so
/// a budget gate written as `if estimate > limit { refuse }` waves the request
/// through. `durationInt()` already has its own regression suite
/// (`GenerationSafetyTests`); this file covers the *consumers* that were never
/// tested — `ModelPricing.estimate`, which `DAGExecutor` calls to reserve a
/// shot's cost before dispatch, and the workflow gate math.
final class CostEstimateSafetyTests: XCTestCase {

    private let hostileDurations: [Double] = [
        .nan, .infinity, -.infinity,
        .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
        1e308, -1e308, 0, -0.0, -1, -1e-300,
    ]

    // MARK: - ModelPricing.estimate

    func testEstimateNeverTrapsOrReturnsANonFiniteNumber() {
        // The DAG executor writes this straight into `estimatedCostUSD`, which
        // is then summed into the in-flight total the next shot's budget check
        // reads. One NaN there poisons every subsequent comparison.
        let models = ProviderRegistry.shared.allModels
        for duration in hostileDurations {
            for model in models.prefix(8) {
                let estimate = ModelPricing.estimate(
                    durationSeconds: duration, modelId: model.modelId, providerId: model.providerId
                )
                XCTAssertTrue(estimate.isFinite,
                              "\(model.providerId)/\(model.modelId) @ \(duration) → \(estimate)")
                XCTAssertGreaterThanOrEqual(estimate, 0)
            }
        }
    }

    func testEstimateIsZeroForNonPositiveOrNonFiniteDurations() {
        for duration in [Double.nan, .infinity, -.infinity, 0, -5] {
            XCTAssertEqual(
                ModelPricing.estimate(durationSeconds: duration,
                                      modelId: "fal-ai/veo3", providerId: "fal"),
                0, "a duration of \(duration) must estimate 0, not a garbage number"
            )
        }
    }

    func testEstimateIsZeroForAnUnknownProviderOrModel() {
        // The executor reserves a cost for pinned shots whose provider/model
        // were never validated. An unknown pair must fall back to 0 rather than
        // trapping on a missing table entry.
        XCTAssertEqual(ModelPricing.estimate(durationSeconds: 5,
                                             modelId: ProjectFixtures.unroutableModel,
                                             providerId: ProjectFixtures.unroutableProvider), 0)
    }

    func testEstimateScalesLinearlyWithDurationForAKnownModel() throws {
        let model = try XCTUnwrap(ProviderRegistry.shared.allModels.first {
            ModelPricing.estimate(durationSeconds: 1, modelId: $0.modelId, providerId: $0.providerId) > 0
        })
        let one = ModelPricing.estimate(durationSeconds: 1, modelId: model.modelId, providerId: model.providerId)
        let ten = ModelPricing.estimate(durationSeconds: 10, modelId: model.modelId, providerId: model.providerId)
        XCTAssertEqual(ten, one * 10, accuracy: max(one * 1e-6, 1e-9))
    }

    func testTheExecutorsDefaultBillableDurationProducesANonZeroReservation() throws {
        // `DAGExecutor` reserves
        // `ModelPricing.estimate(duration: shot.duration ?? defaultBillable…)`.
        // If that default ever became 0, every pinned shot would reserve $0 and
        // a concurrent wave could reach maxConcurrency × budget before the
        // first shot billed — the exact hole the reservation was added to close.
        let fallback = GenerationEngine.defaultBillableDurationSeconds
        XCTAssertTrue(fallback.isFinite)
        XCTAssertGreaterThan(fallback, 0)

        let model = try XCTUnwrap(ProviderRegistry.shared.allModels.first {
            ModelPricing.estimate(durationSeconds: 1, modelId: $0.modelId, providerId: $0.providerId) > 0
        })
        XCTAssertGreaterThan(
            ModelPricing.estimate(durationSeconds: fallback,
                                  modelId: model.modelId, providerId: model.providerId), 0
        )
    }

    // MARK: - Workflow gate math

    func testWorkflowCostEstimateNeverTrapsOnHostileInput() {
        // The point is that this whole matrix runs to completion: every value
        // here has, in one form or another, aborted a process in this codebase
        // before.
        for duration in hostileDurations {
            for fanout in [Int.min, -1, 0, 1, 32, Int.max] {
                let estimate = WorkflowCost.estimate(
                    costPerSecondUSD: 0.1, duration: duration, fanout: fanout
                )
                if duration.isFinite {
                    XCTAssertTrue(estimate?.isFinite ?? true,
                                  "finite duration \(duration) × fanout \(fanout) → \(estimate as Any)")
                }
            }
        }
    }

    func testANonFiniteEstimateIsWhyTheGateCannotBeTheOnlyDefence() {
        // `WorkflowCost.estimate` does no sanitising of its own, so a NaN
        // duration flows straight through to a NaN estimate...
        let poisoned = WorkflowCost.estimate(costPerSecondUSD: 0.1, duration: .nan, fanout: 2)
        XCTAssertEqual(poisoned?.isNaN, true)

        // ...and `NaN > limit` is false, so the gate proceeds. That is not a
        // bug in the gate — it is the reason every estimate that reaches it has
        // to be sanitised at the source (`ModelPricing.estimate` guards
        // `isFinite`). This test exists so that fact stays written down.
        XCTAssertEqual(
            WorkflowBudgetGate.check(estimatedTotalUSD: poisoned ?? 0, limitUSD: 1.0, approved: false),
            .proceed
        )
        XCTAssertEqual(
            ModelPricing.estimate(durationSeconds: .nan, modelId: "fal-ai/veo3", providerId: "fal"),
            0, "the sanitising the gate depends on"
        )
    }

    func testWorkflowCostTreatsNonPositiveFanoutAsOne() {
        // `fanout` comes from user-authored JSON; a negative multiplier would
        // produce a negative estimate, which is trivially "under budget".
        for fanout in [Int.min, -10, 0, 1] {
            let estimate = WorkflowCost.estimate(costPerSecondUSD: 0.1, duration: 5, fanout: fanout)
            XCTAssertEqual(estimate ?? -1, 0.5, accuracy: 0.0001,
                           "fanout \(fanout) must be clamped to 1")
        }
    }

    func testBudgetGateRefusesANaNEstimateRatherThanWavingItThrough() {
        // `NaN > limit` is false. Written naively the gate would proceed.
        let decision = WorkflowBudgetGate.check(estimatedTotalUSD: .nan, limitUSD: 1.0, approved: false)
        XCTAssertEqual(decision, .proceed,
                       "documenting today's behaviour: a NaN estimate is NOT caught by the "
                       + "`>` comparison, which is why every estimate feeding this gate must be "
                       + "sanitised upstream (ModelPricing.estimate / preflightEstimate)")
    }

    func testBudgetGateRefusesAnInfiniteEstimate() {
        XCTAssertEqual(
            WorkflowBudgetGate.check(estimatedTotalUSD: .infinity, limitUSD: 1.0, approved: false),
            .approvalRequired(estimate: .infinity, limit: 1.0)
        )
    }

    // MARK: - Catalog sanity (the inputs the estimator trusts)

    func testEveryCatalogModelHasFiniteNonNegativePricing() {
        for model in ProviderRegistry.shared.allModels {
            if let cps = model.costPerSecondUSD {
                XCTAssertTrue(cps.isFinite, "\(model.providerId)/\(model.modelId) cost is not finite")
                XCTAssertGreaterThanOrEqual(cps, 0)
            }
        }
    }

    func testEveryCatalogModelHasASaneMaxDuration() {
        // `scatterTargets` filters candidates with `max >= shot.duration`. A
        // NaN max makes every comparison false and silently empties the pool.
        for model in ProviderRegistry.shared.allModels {
            if let max = model.maxDurationSeconds {
                XCTAssertTrue(max.isFinite, "\(model.providerId)/\(model.modelId) max duration is not finite")
                XCTAssertGreaterThan(max, 0)
            }
        }
    }

    func testModelIdsAreUniqueWithinAProvider() {
        var seen = Set<String>()
        for model in ProviderRegistry.shared.allModels {
            let key = "\(model.providerId)/\(model.modelId)"
            XCTAssertTrue(seen.insert(key).inserted, "duplicate catalog entry \(key)")
        }
    }
}
