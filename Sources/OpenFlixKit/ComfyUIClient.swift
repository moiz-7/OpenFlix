import Foundation

/// Client for a local ComfyUI server — provider id "local", model "comfyui".
///
/// Zero marginal cost and keyless: the `apiKey` parameter on the protocol
/// methods is ignored (the CLI resolves an empty key for keyless providers).
///
/// The workflow-graph problem, solved simply: ComfyUI executes an arbitrary
/// node graph, and video graphs are rig-specific (they depend on which model
/// checkpoints and custom nodes are installed). So this client takes a GRAPH
/// TEMPLATE — a JSON string containing `{{prompt}}`, `{{negative_prompt}}`,
/// `{{seed}}`, and `{{duration}}` placeholders — and substitutes values with
/// a dumb string replace after JSON-escaping them. The CLI loads the template
/// from `~/.openflix/comfyui-graph.json` when present; the built-in default
/// is a clearly-marked placeholder the user must replace (export a working
/// workflow with "Save (API Format)" in ComfyUI and add the placeholders).
public final class ComfyUIClient: VideoProvider {
    public let providerId = "local"
    public let displayName = "Local (ComfyUI)"

    public let models: [CLIProviderModel] = [
        .priced(providerId: "local", providerName: "Local (ComfyUI)",
            modelId: "comfyui", displayName: "ComfyUI Workflow",
            defaultWidth: nil, defaultHeight: nil,
            maxDurationSeconds: nil, supportsImageToVideo: false),
    ]

    /// Built-in placeholder graph. NOT runnable — video graphs are
    /// rig-specific. The `_comment` node tells the user what to do; ComfyUI
    /// rejects it with a clear validation error if submitted as-is.
    public static let defaultGraphTemplate = """
    {
      "_comment": {
        "class_type": "REPLACE_THIS_PLACEHOLDER_GRAPH",
        "inputs": {
          "how": "Export your own video workflow from ComfyUI with 'Save (API Format)', insert {{prompt}}, {{negative_prompt}}, {{seed}} and {{duration}} placeholders, and save it to ~/.openflix/comfyui-graph.json. Video graphs are rig-specific (checkpoints + custom nodes), so no universal default can be shipped.",
          "positive": "{{prompt}}",
          "negative": "{{negative_prompt}}",
          "seed": {{seed}},
          "duration_seconds": {{duration}}
        }
      }
    }
    """

    private let baseURL: String
    private let graphTemplate: String
    private let clientId = UUID().uuidString
    private let session = makeSession()

    /// - Parameters:
    ///   - baseURL: ComfyUI server root (the CLI wires OPENFLIX_COMFYUI_URL).
    ///   - graphTemplate: workflow-graph JSON template; nil → built-in placeholder.
    public init(baseURL: String = "http://127.0.0.1:8188", graphTemplate: String? = nil) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.graphTemplate = graphTemplate ?? Self.defaultGraphTemplate
    }

    // MARK: - Template substitution (pure)

    /// JSON string-escape a value for insertion between quotes in the template.
    static func jsonEscaped(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let wrapped = String(data: data, encoding: .utf8) else { return value }
        // ["<escaped>"] → drop [" and "]
        return String(wrapped.dropFirst(2).dropLast(2))
    }

    /// Render the graph template: dumb string replace after JSON-escaping.
    /// `{{prompt}}`/`{{negative_prompt}}` are string contents (the template
    /// supplies the quotes); `{{seed}}`/`{{duration}}` are bare JSON numbers.
    public static func renderGraph(template: String, prompt: String,
                                   negativePrompt: String?, seed: Int,
                                   durationSeconds: Double?) -> String {
        let duration = durationSeconds ?? 4
        let durationText = duration.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(duration)) : String(duration)
        return template
            .replacingOccurrences(of: "{{prompt}}", with: jsonEscaped(prompt))
            .replacingOccurrences(of: "{{negative_prompt}}", with: jsonEscaped(negativePrompt ?? ""))
            .replacingOccurrences(of: "{{seed}}", with: String(seed))
            .replacingOccurrences(of: "{{duration}}", with: durationText)
    }

    // MARK: - Submit

    public func submit(request: GenerationRequest, apiKey: String) async throws -> GenerationSubmission {
        let seed = (request.extraParams["seed"] as? Int) ?? Int.random(in: 0..<2_147_483_647)
        let rendered = Self.renderGraph(template: graphTemplate,
                                        prompt: request.prompt,
                                        negativePrompt: request.negativePrompt,
                                        seed: seed,
                                        durationSeconds: request.durationSeconds)
        guard let graph = try? JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any] else {
            throw ProviderError.invalidResponse(
                "ComfyUI graph template is not valid JSON after substitution — check ~/.openflix/comfyui-graph.json")
        }

        guard let url = URL(string: "\(baseURL)/prompt") else {
            throw ProviderError.invalidResponse("Invalid ComfyUI URL: \(baseURL)/prompt")
        }
        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = "POST"
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.httpBody = try JSONSerialization.data(withJSONObject: [
            "prompt": graph,
            "client_id": clientId,
        ])

        let (data, _) = try await session.jsonData(for: urlReq)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let promptId = json?["prompt_id"] as? String else {
            throw ProviderError.invalidResponse("Missing prompt_id in ComfyUI response")
        }
        return GenerationSubmission(
            remoteTaskId: promptId,
            statusURL: URL(string: "\(baseURL)/history/\(promptId)"),
            estimatedCostUSD: estimateCost(durationSeconds: request.durationSeconds ?? 4,
                                           modelId: request.model)
        )
    }

    // MARK: - Poll

    public func poll(taskId: String, statusURL: URL?, apiKey: String) async throws -> PollStatus {
        let url: URL
        if let statusURL = statusURL {
            url = statusURL
        } else {
            guard let encoded = taskId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let fallback = URL(string: "\(baseURL)/history/\(encoded)") else {
                throw ProviderError.invalidResponse("Invalid task ID: \(taskId)")
            }
            url = fallback
        }
        let (data, _) = try await session.jsonData(for: URLRequest(url: url))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return Self.parsePollStatus(json, taskId: taskId, baseURL: baseURL)
    }

    /// Pure parsing of a ComfyUI /history/{prompt_id} response — separated
    /// from the network fetch so it is unit-testable with canned JSON.
    ///
    /// An empty dict (or a dict without the prompt id) means still running.
    /// Completed entries carry outputs keyed by node id; the first node with
    /// a "videos", "gifs", or "images" array wins (in that order), and the
    /// file is downloadable at {base}/view?filename=&subfolder=&type=.
    public static func parsePollStatus(_ json: [String: Any]?, taskId: String, baseURL: String) -> PollStatus {
        guard let entry = json?[taskId] as? [String: Any] else {
            return .processing(progress: nil)
        }
        let status = entry["status"] as? [String: Any]
        let statusStr = status?["status_str"] as? String ?? ""
        if statusStr == "error" {
            return .failed(message: "ComfyUI workflow failed (status_str: error)")
        }
        guard status?["completed"] as? Bool == true else {
            return .processing(progress: nil)
        }

        let outputs = entry["outputs"] as? [String: Any] ?? [:]
        // Deterministic node order; prefer videos over gifs over images.
        for key in ["videos", "gifs", "images"] {
            for nodeId in outputs.keys.sorted() {
                guard let node = outputs[nodeId] as? [String: Any],
                      let files = node[key] as? [[String: Any]],
                      let file = files.first,
                      let filename = file["filename"] as? String else { continue }
                guard var components = URLComponents(string: "\(baseURL)/view") else { continue }
                components.queryItems = [
                    URLQueryItem(name: "filename", value: filename),
                    URLQueryItem(name: "subfolder", value: file["subfolder"] as? String ?? ""),
                    URLQueryItem(name: "type", value: file["type"] as? String ?? "output"),
                ]
                guard let viewURL = components.url else { continue }
                return .succeeded(videoURL: viewURL)
            }
        }
        return .failed(message: "ComfyUI workflow completed but produced no video/gif/image output")
    }
}
