import XCTest
import OpenFlixKit
@testable import openflix

final class PollParsingTests: XCTestCase {

    // MARK: - Replicate

    func testReplicateSucceeded() {
        let json: [String: Any] = [
            "status": "succeeded",
            "output": ["https://replicate.delivery/output/video.mp4"],
        ]
        guard case .succeeded(let url) = ReplicateClient.parsePollStatus(json) else {
            return XCTFail("Expected .succeeded")
        }
        XCTAssertEqual(url.absoluteString, "https://replicate.delivery/output/video.mp4")
    }

    func testReplicateSucceededWithSingleStringOutput() {
        // Several Replicate video models return `output` as a bare URL string,
        // not an array. This must be accepted, else a billed generation is
        // wrongly reported as failed and the user gets nothing.
        let json: [String: Any] = [
            "status": "succeeded",
            "output": "https://replicate.delivery/output/single.mp4",
        ]
        guard case .succeeded(let url) = ReplicateClient.parsePollStatus(json) else {
            return XCTFail("Expected .succeeded for single-string output")
        }
        XCTAssertEqual(url.absoluteString, "https://replicate.delivery/output/single.mp4")
    }

    func testReplicateSucceededWithoutOutputFails() {
        let json: [String: Any] = ["status": "succeeded"]
        guard case .failed(let message) = ReplicateClient.parsePollStatus(json) else {
            return XCTFail("Expected .failed")
        }
        XCTAssertTrue(message.contains("No output URL"))
    }

    func testReplicateFailedCarriesErrorMessage() {
        let json: [String: Any] = ["status": "failed", "error": "NSFW content detected"]
        guard case .failed(let message) = ReplicateClient.parsePollStatus(json) else {
            return XCTFail("Expected .failed")
        }
        XCTAssertEqual(message, "NSFW content detected")
    }

    func testReplicateProcessingAndUnknownStatuses() {
        guard case .processing = ReplicateClient.parsePollStatus(["status": "processing"]) else {
            return XCTFail("Expected .processing")
        }
        guard case .queued = ReplicateClient.parsePollStatus(["status": "some_new_status"]) else {
            return XCTFail("Unknown status should map to .queued")
        }
    }

    // MARK: - Runway

    func testRunwaySucceeded() {
        let json: [String: Any] = [
            "status": "SUCCEEDED",
            "output": ["https://cdn.runwayml.com/task/video.mp4"],
        ]
        guard case .succeeded(let url) = RunwayClient.parsePollStatus(json) else {
            return XCTFail("Expected .succeeded")
        }
        XCTAssertEqual(url.absoluteString, "https://cdn.runwayml.com/task/video.mp4")
    }

    func testRunwayRunningCarriesProgress() {
        let json: [String: Any] = ["status": "RUNNING", "progress": 0.42]
        guard case .processing(let progress) = RunwayClient.parsePollStatus(json) else {
            return XCTFail("Expected .processing")
        }
        XCTAssertEqual(progress ?? -1, 0.42, accuracy: 0.0001)
    }

    func testRunwayFailedCarriesFailureMessage() {
        let json: [String: Any] = ["status": "FAILED", "failure": "content policy violation"]
        guard case .failed(let message) = RunwayClient.parsePollStatus(json) else {
            return XCTFail("Expected .failed")
        }
        XCTAssertEqual(message, "content policy violation")
    }

    func testRunwayPendingAndThrottledAreQueued() {
        guard case .queued = RunwayClient.parsePollStatus(["status": "PENDING"]) else {
            return XCTFail("Expected .queued for PENDING")
        }
        guard case .queued = RunwayClient.parsePollStatus(["status": "THROTTLED"]) else {
            return XCTFail("Expected .queued for THROTTLED")
        }
    }

    // MARK: - Cancel support

    func testCancelNotSupportedErrorShape() async {
        let luma = LumaClient()
        do {
            try await luma.cancel(taskId: "t1", statusURL: nil, apiKey: "k")
            XCTFail("Expected cancelNotSupported to be thrown")
        } catch let error as ProviderError {
            // The default cancel lives in OpenFlixKit and throws ProviderError...
            guard case .cancelNotSupported(let provider) = error else {
                return XCTFail("Expected .cancelNotSupported, got \(error)")
            }
            XCTAssertEqual(provider, "Luma")
            XCTAssertEqual(error.code, "cancel_not_supported")
            XCTAssertEqual(error.errorDescription, "cancel not supported by Luma")
            // ...and the CLI boundary mapping preserves the exact JSON error shape.
            let mapped = OpenFlixError(error)
            guard case .cancelNotSupported(let mappedProvider) = mapped else {
                return XCTFail("Expected mapped .cancelNotSupported, got \(mapped)")
            }
            XCTAssertEqual(mappedProvider, "Luma")
            XCTAssertEqual(mapped.code, "cancel_not_supported")
            XCTAssertEqual(mapped.errorDescription, "cancel not supported by Luma")
        } catch {
            XCTFail("Expected ProviderError, got \(error)")
        }
    }
}
