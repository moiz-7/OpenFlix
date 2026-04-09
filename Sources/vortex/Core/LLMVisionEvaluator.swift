import Foundation

/// Evaluates video quality using ffmpeg frame extraction and Claude Vision API.
/// 1. Extract N evenly-spaced frames via `ffmpeg -vframes`
/// 2. Base64-encode JPEG frames
/// 3. Call Claude API with multimodal content
/// 4. Parse structured JSON response with 5 dimensions
struct LLMVisionEvaluator: VideoEvaluator {
    let evaluatorId = "llm-vision"

    func evaluate(generation: CLIGeneration, videoPath: String, shot: Shot?, config: QualityConfig) async throws -> EvaluationResult {
        // 1. Resolve API key
        guard let apiKey = config.claudeApiKey ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] else {
            throw VortexError.invalidResponse("No Claude API key. Set ANTHROPIC_API_KEY or pass --claude-api-key")
        }

        // 2. Extract frames
        let frames = try await extractFrames(videoPath: videoPath, count: config.maxFrames)
        guard !frames.isEmpty else {
            throw VortexError.invalidResponse("Failed to extract frames from video")
        }

        // 3. Build prompt
        let promptText = buildEvaluationPrompt(generation: generation, shot: shot)

        // 4. Call Claude API
        let response = try await callClaudeAPI(
            apiKey: apiKey,
            model: config.claudeModel,
            frames: frames,
            prompt: promptText
        )

        // 5. Parse response
        let result = try parseResponse(response, threshold: config.threshold)
        return result
    }

    // MARK: - Frame Extraction

    private func extractFrames(videoPath: String, count: Int) async throws -> [Data] {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vortex_eval_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Get duration first
        let duration = try await getVideoDuration(videoPath: videoPath)
        var frames: [Data] = []

        for i in 0..<count {
            let timestamp: Double
            if count == 1 {
                timestamp = duration / 2
            } else {
                timestamp = (duration / Double(count + 1)) * Double(i + 1)
            }

            let outputPath = tempDir.appendingPathComponent("frame_\(i).jpg").path

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [
                "ffmpeg", "-y", "-ss", String(format: "%.2f", timestamp),
                "-i", videoPath, "-vframes", "1", "-q:v", "2", outputPath
            ]
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            defer {
                outPipe.fileHandleForReading.closeFile()
                errPipe.fileHandleForReading.closeFile()
            }

            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0,
               let data = FileManager.default.contents(atPath: outputPath) {
                frames.append(data)
            }
        }

        return frames
    }

    private func getVideoDuration(videoPath: String) async throws -> Double {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "ffprobe", "-v", "quiet", "-show_entries", "format=duration",
            "-of", "csv=p=0", videoPath
        ]

        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe
        defer {
            pipe.fileHandleForReading.closeFile()
            errPipe.fileHandleForReading.closeFile()
        }

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Double(str) ?? 5.0 // default 5 seconds if can't determine
    }

    // MARK: - Claude API

    private func buildEvaluationPrompt(generation: CLIGeneration, shot: Shot?) -> String {
        var prompt = """
        You are evaluating frames extracted from an AI-generated video.

        Original prompt: "\(generation.prompt)"
        """
        if let neg = generation.negativePrompt {
            prompt += "\nNegative prompt: \"\(neg)\""
        }
        if let s = shot {
            prompt += "\nShot name: \(s.name)"
        }
        prompt += """


        Score each dimension from 0-100:
        1. prompt_adherence: How well does the video match the generation prompt?
        2. visual_quality: Sharpness, color accuracy, absence of artifacts
        3. temporal_coherence: Consistency between frames, smooth motion (infer from frame progression)
        4. composition: Framing, balance, visual appeal
        5. technical_quality: Resolution, encoding quality, absence of glitches

        Respond with ONLY valid JSON in this exact format:
        {
            "prompt_adherence": <score>,
            "visual_quality": <score>,
            "temporal_coherence": <score>,
            "composition": <score>,
            "technical_quality": <score>,
            "reasoning": "<brief explanation>"
        }
        """
        return prompt
    }

    private func callClaudeAPI(apiKey: String, model: String, frames: [Data], prompt: String) async throws -> [String: Any] {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw VortexError.invalidResponse("Invalid Anthropic API URL")
        }

        var content: [[String: Any]] = []
        for frame in frames {
            let base64 = frame.base64EncodedString()
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": base64,
                ] as [String: Any]
            ])
        }
        content.append([
            "type": "text",
            "text": prompt,
        ])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "messages": [
                ["role": "user", "content": content]
            ]
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = bodyData
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw VortexError.invalidResponse("Non-HTTP response from Claude API")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8)?.prefix(500) ?? ""
            throw VortexError.httpError(httpResponse.statusCode, "Claude API: \(body)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentArray = json["content"] as? [[String: Any]],
              let textBlock = contentArray.first(where: { ($0["type"] as? String) == "text" }),
              let text = textBlock["text"] as? String else {
            throw VortexError.invalidResponse("Unexpected Claude API response format")
        }

        // Extract JSON from response text (may be wrapped in markdown code block)
        let jsonText = extractJSON(from: text)
        guard let resultData = jsonText.data(using: .utf8),
              let result = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] else {
            throw VortexError.invalidResponse("Could not parse Claude evaluation response as JSON")
        }

        return result
    }

    private func extractJSON(from text: String) -> String {
        // Try to extract JSON from markdown code blocks
        let patterns = [
            try? NSRegularExpression(pattern: "```json\\s*\\n(.+?)```", options: .dotMatchesLineSeparators),
            try? NSRegularExpression(pattern: "```\\s*\\n(.+?)```", options: .dotMatchesLineSeparators),
        ]
        for pattern in patterns.compactMap({ $0 }) {
            if let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let range = Range(match.range(at: 1), in: text) {
                return String(text[range])
            }
        }
        // Assume the whole text is JSON
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Response Parsing

    private func parseResponse(_ response: [String: Any], threshold: Double) throws -> EvaluationResult {
        let dims = [
            "prompt_adherence",
            "visual_quality",
            "temporal_coherence",
            "composition",
            "technical_quality",
        ]

        var dimensions: [String: Double] = [:]
        var total: Double = 0

        for dim in dims {
            let val: Double
            if let v = response[dim] as? Double {
                val = v
            } else if let v = response[dim] as? Int {
                val = Double(v)
            } else {
                val = 50 // default mid-score
            }
            dimensions[dim] = val
            total += val
        }

        let avgScore = total / Double(dims.count)
        let reasoning = (response["reasoning"] as? String) ?? "LLM evaluation completed"

        return EvaluationResult(
            score: avgScore,
            passed: avgScore >= threshold,
            reasoning: reasoning,
            evaluator: "llm-vision",
            dimensions: dimensions,
            evaluatedAt: Date()
        )
    }
}
