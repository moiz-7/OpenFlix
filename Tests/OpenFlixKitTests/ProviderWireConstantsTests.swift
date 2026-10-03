import XCTest
@testable import OpenFlixKit

/// The provider base URLs are string literals unwrapped at first use. This is
/// what makes those unwraps safe: every one of them parses, is https, and has
/// a host. A typo in one fails here, not in the middle of a paid request.
final class ProviderWireConstantsTests: XCTestCase {

    func testEveryProviderBaseURLIsAValidHTTPSURL() {
        let bases: [(String, URL)] = [
            ("kling", KlingWire.defaultBase), ("runway", RunwayWire.defaultBase),
            ("minimax", MiniMaxWire.defaultBase), ("fal", FalWire.queueBase),
            ("luma", LumaWire.defaultBase), ("fal-upload", FalUpload.initiateURL),
        ]
        for (name, url) in bases {
            XCTAssertEqual(url.scheme, "https", name)
            XCTAssertFalse((url.host ?? "").isEmpty, name)
        }
    }

    func testKlingPollURLEncodesWhateverTaskIdItIsGiven() {
        for id in ["abc-123", "a b&c=d", "ü/../x", ""] {
            let url = KlingWire.pollURL(taskId: id)
            XCTAssertEqual(url.host, KlingWire.defaultBase.host, id)
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(items?.first { $0.name == "task_ids" }?.value, id, id)
        }
    }
}
