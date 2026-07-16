import XCTest
import OpenFlixKit
@testable import openflix

final class ModelPricingTests: XCTestCase {

    func testKnownModelLookup() {
        XCTAssertEqual(ModelPricing.costPerSecond("fal-ai/veo3", providerId: "fal"), 0.15)
        XCTAssertEqual(ModelPricing.costPerSecond("ray-3", providerId: "luma"), 0.20)
        XCTAssertEqual(ModelPricing.costPerSecond("kling-v2.5-turbo", providerId: "kling"), 0.03)
    }

    func testUnknownModelFallsBackPerProviderThenGlobally() {
        XCTAssertEqual(ModelPricing.costPerSecond("luma/unlisted", providerId: "luma"), 0.10)
        XCTAssertEqual(ModelPricing.costPerSecond("fal/unlisted", providerId: "fal"), 0.05)
        XCTAssertEqual(ModelPricing.costPerSecond("x", providerId: "unknown-provider"),
                       ModelPricing.globalFallbackUSD)
    }

    func testEstimateIsRatePerSecondTimesDuration() {
        XCTAssertEqual(ModelPricing.estimate(durationSeconds: 8, modelId: "fal-ai/veo3",
                                             providerId: "fal"), 1.2, accuracy: 1e-9)
    }

    func testEstimateGuardsNonFiniteAndNegativeDurations() {
        // A NaN estimate silently defeats budget gates (NaN > limit is always
        // false); a negative duration would yield a negative "credit". Both → 0.
        XCTAssertEqual(ModelPricing.estimate(durationSeconds: .nan, modelId: "fal-ai/veo3", providerId: "fal"), 0)
        XCTAssertEqual(ModelPricing.estimate(durationSeconds: .infinity, modelId: "fal-ai/veo3", providerId: "fal"), 0)
        XCTAssertEqual(ModelPricing.estimate(durationSeconds: -5, modelId: "fal-ai/veo3", providerId: "fal"), 0)
    }

    func testEveryCatalogModelHasAnExplicitPricingEntry() {
        // Guards against adding a model to a provider catalog without adding
        // its price to the single table.
        for model in ProviderRegistry.shared.allModels {
            XCTAssertNotNil(ModelPricing.costPerSecondUSD[model.modelId],
                            "model '\(model.modelId)' (\(model.providerId)) missing from ModelPricing.costPerSecondUSD")
        }
    }

    func testCatalogEntriesReadThePricingTable() {
        // .priced(...) sources costPerSecondUSD from the table verbatim.
        for model in ProviderRegistry.shared.allModels {
            XCTAssertEqual(model.costPerSecondUSD,
                           ModelPricing.costPerSecondUSD[model.modelId],
                           "catalog price for '\(model.modelId)' diverges from ModelPricing")
        }
    }

    func testProviderEstimateCostUsesSharedTable() {
        let fal = FalClient()
        XCTAssertEqual(fal.estimateCost(durationSeconds: 4, modelId: "fal-ai/veo3"), 0.6)
        // Unknown model → provider fallback, never nil
        XCTAssertEqual(fal.estimateCost(durationSeconds: 4, modelId: "nope"), 0.2)
    }
}
