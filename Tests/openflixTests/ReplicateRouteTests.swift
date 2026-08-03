import XCTest
import OpenFlixKit
@testable import openflix

/// Regression tests for Replicate submit routing.
///
/// Every model in the catalog is a SLUG ("minimax/video-01-live"), and all of
/// them were being POSTed to `/v1/predictions` as `{"version": "<slug>"}`.
/// Replicate's `version` field takes a 64-char version hash; official models
/// are submitted at `/v1/models/{owner}/{name}/predictions`. So every
/// Replicate submission should have 422'd — the signature of an integration
/// written from documentation and never run against the live API.
final class ReplicateRouteTests: XCTestCase {

    private let input: [String: Any] = ["prompt": "a golden sunset"]

    // MARK: - Model slugs

    func testSlugUsesTheModelsEndpointAndOmitsVersion() throws {
        let route = try ReplicateClient.submitRoute(model: "minimax/video-01-live", input: input)
        XCTAssertEqual(route.url.absoluteString,
                       "https://api.replicate.com/v1/models/minimax/video-01-live/predictions")
        XCTAssertNil(route.body["version"],
                     "a slug must NOT be sent in the version field — that is the original bug")
        XCTAssertNotNil(route.body["input"])
    }

    func testEveryCatalogModelRoutesToTheModelsEndpoint() throws {
        // Guards against a future catalog entry silently reintroducing the bug.
        for model in ReplicateClient().models {
            let route = try ReplicateClient.submitRoute(model: model.modelId, input: input)
            XCTAssertTrue(route.url.absoluteString.contains("/v1/models/"),
                          "\(model.modelId) should use the models endpoint")
            XCTAssertNil(route.body["version"], "\(model.modelId) must not send a version")
        }
    }

    // MARK: - Pinned version hashes

    func testVersionHashUsesThePredictionsEndpoint() throws {
        let hash = String(repeating: "a1b2c3d4", count: 8)  // 64 hex chars
        XCTAssertEqual(hash.count, 64)

        let route = try ReplicateClient.submitRoute(model: hash, input: input)
        XCTAssertEqual(route.url.absoluteString, "https://api.replicate.com/v1/predictions")
        XCTAssertEqual(route.body["version"] as? String, hash)
    }

    func testLength64ButNonHexIsTreatedAsASlugNotAVersion() throws {
        // Exactly 64 characters, but contains a slash and non-hex letters, so
        // it is a slug — length alone must not promote it to a version hash.
        let notAHash = "owner/" + String(repeating: "z", count: 58)
        XCTAssertEqual(notAHash.count, 64)
        let route = try ReplicateClient.submitRoute(model: notAHash, input: input)
        XCTAssertTrue(route.url.absoluteString.contains("/v1/models/"))
        XCTAssertNil(route.body["version"])
    }

    // MARK: - Malformed input fails loudly, not at the provider

    func testEmptyModelThrows() {
        XCTAssertThrowsError(try ReplicateClient.submitRoute(model: "   ", input: input))
    }

    func testSingleSegmentModelThrows() {
        // "hunyuan-video" is neither owner/name nor a version hash. Better to
        // reject locally than to send a malformed request and surface the
        // provider's opaque error.
        XCTAssertThrowsError(try ReplicateClient.submitRoute(model: "hunyuan-video", input: input)) { error in
            guard let e = error as? ProviderError else { return XCTFail("wrong error type") }
            XCTAssertTrue((e.errorDescription ?? "").contains("owner/name"))
        }
    }

    func testTooManySegmentsThrows() {
        XCTAssertThrowsError(try ReplicateClient.submitRoute(model: "a/b/c", input: input))
    }

    func testEmptyOwnerOrNameThrows() {
        XCTAssertThrowsError(try ReplicateClient.submitRoute(model: "/name", input: input))
        XCTAssertThrowsError(try ReplicateClient.submitRoute(model: "owner/", input: input))
    }

    func testInputIsCarriedThroughUnchanged() throws {
        let richInput: [String: Any] = ["prompt": "x", "num_frames": 40, "width": 1280]
        let route = try ReplicateClient.submitRoute(model: "tencent/hunyuan-video", input: richInput)
        let body = route.body["input"] as? [String: Any]
        XCTAssertEqual(body?["num_frames"] as? Int, 40)
        XCTAssertEqual(body?["width"] as? Int, 1280)
        XCTAssertEqual(body?["prompt"] as? String, "x")
    }
}
