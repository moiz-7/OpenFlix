import XCTest
@testable import OpenFlixKit

final class ComfyUIClientTests: XCTestCase {

    private let base = "http://127.0.0.1:8188"

    // MARK: - Template substitution

    func testRenderGraphSubstitutesAllPlaceholders() {
        let template = """
        {"1": {"inputs": {"text": "{{prompt}}", "neg": "{{negative_prompt}}", "seed": {{seed}}, "frames": {{duration}}}}}
        """
        let rendered = ComfyUIClient.renderGraph(
            template: template, prompt: "a red fox",
            negativePrompt: "blurry", seed: 42, durationSeconds: 5)
        let json = try? JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any]
        let inputs = (json?["1"] as? [String: Any])?["inputs"] as? [String: Any]
        XCTAssertEqual(inputs?["text"] as? String, "a red fox")
        XCTAssertEqual(inputs?["neg"] as? String, "blurry")
        XCTAssertEqual(inputs?["seed"] as? Int, 42)
        XCTAssertEqual(inputs?["frames"] as? Int, 5)
    }

    func testRenderGraphJSONEscapesSpecialCharacters() {
        // Quotes, backslashes, and newlines in the prompt must not break the
        // graph JSON — substitution is dumb string replace AFTER escaping.
        let template = #"{"n": {"inputs": {"text": "{{prompt}}", "seed": {{seed}}, "d": {{duration}}}}}"#
        let nasty = "say \"hi\"\\ then\nnewline"
        let rendered = ComfyUIClient.renderGraph(
            template: template, prompt: nasty,
            negativePrompt: nil, seed: 1, durationSeconds: nil)
        let json = try? JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any]
        XCTAssertNotNil(json, "rendered graph must stay valid JSON")
        let inputs = (json?["n"] as? [String: Any])?["inputs"] as? [String: Any]
        XCTAssertEqual(inputs?["text"] as? String, nasty)
        // duration defaults to 4 when unset
        XCTAssertEqual(inputs?["d"] as? Int, 4)
    }

    func testRenderGraphNilNegativePromptBecomesEmptyString() {
        let template = #"{"n": {"inputs": {"neg": "{{negative_prompt}}"}}}"#
        let rendered = ComfyUIClient.renderGraph(
            template: template, prompt: "p", negativePrompt: nil,
            seed: 0, durationSeconds: 4)
        let json = try? JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any]
        let inputs = (json?["n"] as? [String: Any])?["inputs"] as? [String: Any]
        XCTAssertEqual(inputs?["neg"] as? String, "")
    }

    func testRenderGraphFractionalDurationKeepsDecimal() {
        let template = #"{"n": {"inputs": {"d": {{duration}}}}}"#
        let rendered = ComfyUIClient.renderGraph(
            template: template, prompt: "p", negativePrompt: nil,
            seed: 0, durationSeconds: 2.5)
        XCTAssertTrue(rendered.contains("\"d\": 2.5"))
    }

    // MARK: - Poll parsing (canned /history/{prompt_id} fixtures)

    func testPollEmptyHistoryMeansStillRunning() {
        guard case .processing = ComfyUIClient.parsePollStatus([:], taskId: "t1", baseURL: base) else {
            return XCTFail("Empty history dict should map to .processing")
        }
        guard case .processing = ComfyUIClient.parsePollStatus(nil, taskId: "t1", baseURL: base) else {
            return XCTFail("nil history should map to .processing")
        }
    }

    func testPollCompletedWithVideoOutput() {
        let json: [String: Any] = [
            "t1": [
                "status": ["completed": true, "status_str": "success"],
                "outputs": [
                    "9": ["videos": [["filename": "out 1.mp4", "subfolder": "sub dir", "type": "output"]]],
                ],
            ],
        ]
        guard case .succeeded(let url) = ComfyUIClient.parsePollStatus(json, taskId: "t1", baseURL: base) else {
            return XCTFail("Expected .succeeded")
        }
        // Download URL is {base}/view with percent-encoded query values.
        XCTAssertTrue(url.absoluteString.hasPrefix("\(base)/view?"))
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        XCTAssertEqual(comps?.queryItems?.first { $0.name == "filename" }?.value, "out 1.mp4")
        XCTAssertEqual(comps?.queryItems?.first { $0.name == "subfolder" }?.value, "sub dir")
        XCTAssertEqual(comps?.queryItems?.first { $0.name == "type" }?.value, "output")
    }

    func testPollPrefersVideosOverGifsOverImages() {
        let json: [String: Any] = [
            "t1": [
                "status": ["completed": true, "status_str": "success"],
                "outputs": [
                    "3": ["images": [["filename": "frame.png", "subfolder": "", "type": "output"]]],
                    "7": ["gifs": [["filename": "anim.gif", "subfolder": "", "type": "output"]]],
                    "9": ["videos": [["filename": "clip.mp4", "subfolder": "", "type": "output"]]],
                ],
            ],
        ]
        guard case .succeeded(let url) = ComfyUIClient.parsePollStatus(json, taskId: "t1", baseURL: base) else {
            return XCTFail("Expected .succeeded")
        }
        XCTAssertTrue(url.absoluteString.contains("filename=clip.mp4"))
    }

    func testPollGifOutputWhenNoVideos() {
        let json: [String: Any] = [
            "t1": [
                "status": ["completed": true, "status_str": "success"],
                "outputs": [
                    "7": ["gifs": [["filename": "anim.gif", "subfolder": "", "type": "output"]]],
                ],
            ],
        ]
        guard case .succeeded(let url) = ComfyUIClient.parsePollStatus(json, taskId: "t1", baseURL: base) else {
            return XCTFail("Expected .succeeded")
        }
        XCTAssertTrue(url.absoluteString.contains("filename=anim.gif"))
    }

    func testPollErrorStatusFails() {
        let json: [String: Any] = [
            "t1": [
                "status": ["completed": false, "status_str": "error"],
                "outputs": [String: Any](),
            ],
        ]
        guard case .failed(let message) = ComfyUIClient.parsePollStatus(json, taskId: "t1", baseURL: base) else {
            return XCTFail("Expected .failed")
        }
        XCTAssertTrue(message.contains("error"))
    }

    func testPollCompletedWithoutOutputsFails() {
        let json: [String: Any] = [
            "t1": [
                "status": ["completed": true, "status_str": "success"],
                "outputs": [String: Any](),
            ],
        ]
        guard case .failed(let message) = ComfyUIClient.parsePollStatus(json, taskId: "t1", baseURL: base) else {
            return XCTFail("Expected .failed")
        }
        XCTAssertTrue(message.contains("no video"))
    }

    func testPollNotCompletedYetIsProcessing() {
        let json: [String: Any] = [
            "t1": ["status": ["completed": false, "status_str": "running"]],
        ]
        guard case .processing = ComfyUIClient.parsePollStatus(json, taskId: "t1", baseURL: base) else {
            return XCTFail("Expected .processing while not completed")
        }
    }

    // MARK: - Zero-cost + catalog

    func testEstimateCostIsZero() {
        let client = ComfyUIClient()
        XCTAssertEqual(client.estimateCost(durationSeconds: 60, modelId: "comfyui"), 0.0)
        // Unknown model still resolves through the provider fallback: $0.
        XCTAssertEqual(client.estimateCost(durationSeconds: 60, modelId: "anything"), 0.0)
    }

    func testProviderIdentityAndCatalog() {
        let client = ComfyUIClient()
        XCTAssertEqual(client.providerId, "local")
        XCTAssertEqual(client.models.map { $0.modelId }, ["comfyui"])
        XCTAssertEqual(client.models.first?.costPerSecondUSD, 0.0)
    }

    func testDefaultTemplateContainsAllPlaceholders() {
        for placeholder in ["{{prompt}}", "{{negative_prompt}}", "{{seed}}", "{{duration}}"] {
            XCTAssertTrue(ComfyUIClient.defaultGraphTemplate.contains(placeholder),
                          "default template missing \(placeholder)")
        }
        // The default is deliberately a placeholder the user must replace.
        XCTAssertTrue(ComfyUIClient.defaultGraphTemplate.contains("REPLACE_THIS_PLACEHOLDER_GRAPH"))
    }
}
