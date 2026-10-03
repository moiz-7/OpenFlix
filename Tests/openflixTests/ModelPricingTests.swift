import XCTest
import OpenFlixKit
@testable import openflix

/// Prices pinned to the providers' published rates as verified on 2026-09-27
/// (see VideoModelCatalog.swift for sources). If a provider changes a price,
/// change the catalog AND this test, deliberately.
final class ModelPricingTests: XCTestCase {

    func testKnownModelLookup() {
        // fal Veo 3: $0.20/s audio off, $0.40/s audio on — and fal turns
        // audio ON by default, so the default rate is the audio rate. The old
        // table said $0.15/s, under-estimating every clip by ~2.7×.
        XCTAssertEqual(ModelPricing.costPerSecond("fal-ai/veo3", providerId: "fal"), 0.40, accuracy: 1e-9)
        // fal Kling 2 Master: $1.40 per 5 s. The old table said $0.06/s.
        XCTAssertEqual(ModelPricing.costPerSecond("fal-ai/kling-video/v2/master/text-to-video", providerId: "fal"),
                       0.28, accuracy: 1e-9)
        // Kling direct, 2.5 Turbo at 720p: 0.3 units = $0.042/s.
        XCTAssertEqual(ModelPricing.costPerSecond("kling-v2.5-turbo", providerId: "kling"), 0.042, accuracy: 1e-9)
        // Runway Gen-4.5: 12 credits/s at $0.01.
        XCTAssertEqual(ModelPricing.costPerSecond("gen4.5", providerId: "runway"), 0.12, accuracy: 1e-9)
    }

    func testUnknownModelFallsBackPerProviderThenGlobally() {
        // Fallbacks are deliberately near the top of each provider's catalog:
        // an uncatalogued model must never be priced below what it can bill.
        XCTAssertEqual(ModelPricing.costPerSecond("luma/unlisted", providerId: "luma"),
                       ModelPricing.providerFallbackUSD["luma"])
        XCTAssertEqual(ModelPricing.costPerSecond("fal/unlisted", providerId: "fal"),
                       ModelPricing.providerFallbackUSD["fal"])
        XCTAssertEqual(ModelPricing.costPerSecond("x", providerId: "unknown-provider"),
                       ModelPricing.globalFallbackUSD)
        for (provider, rate) in ModelPricing.providerFallbackUSD where provider != "local" {
            let catalogMax = VideoModelCatalog.models(for: provider).map(\.defaultCostPerSecond).max() ?? 0
            XCTAssertGreaterThanOrEqual(rate + 1e-9, min(catalogMax, 0.40),
                                        "\(provider) fallback is below its own catalog")
        }
    }

    func testEstimateIsRateTimesBilledDuration() {
        // 8 s of fal Veo 3 at the default (audio on) rate.
        XCTAssertEqual(ModelPricing.estimate(durationSeconds: 8, modelId: "fal-ai/veo3", providerId: "fal"),
                       3.2, accuracy: 1e-9)
    }

    func testDurationIsRoundedUpToWhatTheProviderBills() {
        // Veo takes 4/6/8 s. A 5 s request becomes 6 s — never 4 — so the user
        // gets at least what they asked for and the estimate covers the bill.
        let spec = try! XCTUnwrap(VideoModelCatalog.spec(provider: "fal", model: "fal-ai/veo3"))
        XCTAssertEqual(spec.billedSeconds(requested: 5), 6)
        XCTAssertEqual(spec.billedSeconds(requested: 9), 8, "above the maximum clamps to the maximum")
        XCTAssertEqual(ModelPricing.estimate(durationSeconds: 5, modelId: "fal-ai/veo3", providerId: "fal"),
                       6 * 0.40, accuracy: 1e-9)
    }

    func testExplicitAudioOffUsesTheLowerRate() {
        let on = ModelPricing.estimate(durationSeconds: 8, modelId: "fal-ai/veo3.1", providerId: "fal", audio: true)
        let off = ModelPricing.estimate(durationSeconds: 8, modelId: "fal-ai/veo3.1", providerId: "fal", audio: false)
        XCTAssertEqual(on, 3.2, accuracy: 1e-9)
        XCTAssertEqual(off, 1.6, accuracy: 1e-9)
    }

    func testUnknownResolutionTakesTheHighestMatchingRate() {
        // A budget gate must over-estimate. Kling 3.0 with audio unspecified
        // uses its default (off); with resolution unknown-to-the-table the
        // highest rate wins.
        let spec = try! XCTUnwrap(VideoModelCatalog.spec(provider: "kling", model: "kling-3.0"))
        XCTAssertEqual(spec.estimateUSD(requestedSeconds: 5, resolution: "8k"), 5 * 0.42, accuracy: 1e-9)
    }

    func testPerVideoPricingIgnoresDuration() {
        XCTAssertEqual(ModelPricing.estimate(durationSeconds: 3, modelId: "fal-ai/luma-dream-machine", providerId: "fal"), 0.50)
        XCTAssertEqual(ModelPricing.estimate(durationSeconds: 30, modelId: "fal-ai/luma-dream-machine", providerId: "fal"), 0.50)
    }

    func testEstimateGuardsNonFiniteAndNegativeDurations() {
        // A NaN estimate silently defeats budget gates (NaN > limit is always
        // false); a negative duration would yield a negative "credit". Both → 0.
        XCTAssertEqual(ModelPricing.estimate(durationSeconds: .nan, modelId: "fal-ai/veo3", providerId: "fal"), 0)
        XCTAssertEqual(ModelPricing.estimate(durationSeconds: .infinity, modelId: "fal-ai/veo3", providerId: "fal"), 0)
        XCTAssertEqual(ModelPricing.estimate(durationSeconds: -5, modelId: "fal-ai/veo3", providerId: "fal"), 0)
        // …and an absurd finite value must not trap on the Int conversion.
        XCTAssertGreaterThan(ModelPricing.estimate(durationSeconds: 1e300, modelId: "fal-ai/veo3", providerId: "fal"), 0)
    }

    func testEveryCatalogModelHasAnExplicitPricingEntry() {
        for model in ProviderRegistry.shared.allModels {
            XCTAssertNotNil(ModelPricing.costPerSecondUSD[model.modelId],
                            "model '\(model.modelId)' (\(model.providerId)) missing from ModelPricing.costPerSecondUSD")
        }
    }

    func testCatalogEntriesReadThePricingTable() {
        for model in ProviderRegistry.shared.allModels {
            XCTAssertEqual(model.costPerSecondUSD ?? -1,
                           ModelPricing.costPerSecondUSD[model.modelId] ?? -2, accuracy: 1e-9,
                           "catalog price for '\(model.modelId)' diverges from ModelPricing")
        }
    }

    func testProviderEstimateCostUsesSharedTable() {
        let fal = FalClient()
        XCTAssertEqual(fal.estimateCost(durationSeconds: 4, modelId: "fal-ai/veo3") ?? 0, 1.6, accuracy: 1e-9)
        // Unknown model → provider fallback, never nil
        XCTAssertEqual(fal.estimateCost(durationSeconds: 4, modelId: "nope") ?? 0,
                       4 * (ModelPricing.providerFallbackUSD["fal"] ?? 0), accuracy: 1e-9)
    }
}
