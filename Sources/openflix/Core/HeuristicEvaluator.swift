import Foundation

/// Evaluates video quality using file metadata and ffprobe.
/// Scoring (100 points max):
/// - File exists & non-empty (20 pts)
/// - File size reasonable 50KB-2GB (20 pts)
/// - Video file extension (10 pts)
/// - ffprobe: duration match ±20% (10), resolution >= 720p (10), video codec present (10)
/// - Generation succeeded without errors (20 pts)
struct HeuristicEvaluator: VideoEvaluator {
    let evaluatorId = "heuristic"

    func evaluate(generation: CLIGeneration, videoPath: String, shot: Shot?, config: QualityConfig) async throws -> EvaluationResult {
        var score: Double = 0
        var dimensions: [String: Double] = [:]
        var reasons: [String] = []

        let fm = FileManager.default

        // 1. File exists & non-empty (20 pts)
        var fileScore: Double = 0
        if fm.fileExists(atPath: videoPath) {
            let attrs = try? fm.attributesOfItem(atPath: videoPath)
            let size = attrs?[.size] as? UInt64 ?? 0
            if size > 0 {
                fileScore = 20
                reasons.append("File exists (\(size) bytes)")
            } else {
                reasons.append("File exists but empty")
            }
        } else {
            reasons.append("File not found at path")
        }
        dimensions["file_exists"] = fileScore
        score += fileScore

        // 2. File size reasonable 50KB-2GB (20 pts)
        var sizeScore: Double = 0
        if let attrs = try? fm.attributesOfItem(atPath: videoPath),
           let size = attrs[.size] as? UInt64 {
            let minSize: UInt64 = 50 * 1024           // 50KB
            let maxSize: UInt64 = 2 * 1024 * 1024 * 1024 // 2GB
            if size >= minSize && size <= maxSize {
                sizeScore = 20
                reasons.append("File size reasonable")
            } else if size < minSize {
                sizeScore = 5
                reasons.append("File suspiciously small (<50KB)")
            } else {
                sizeScore = 10
                reasons.append("File unusually large (>2GB)")
            }
        }
        dimensions["file_size"] = sizeScore
        score += sizeScore

        // 3. Video file extension (10 pts)
        var extScore: Double = 0
        let videoExtensions: Set<String> = ["mp4", "mov", "avi", "mkv", "webm", "m4v"]
        let ext = (videoPath as NSString).pathExtension.lowercased()
        if videoExtensions.contains(ext) {
            extScore = 10
            reasons.append("Valid video extension: .\(ext)")
        } else if !ext.isEmpty {
            extScore = 2
            reasons.append("Non-standard extension: .\(ext)")
        } else {
            reasons.append("No file extension")
        }
        dimensions["file_extension"] = extScore
        score += extScore

        // 4. ffprobe metadata (30 pts total)
        let probeResult = await runFfprobe(videoPath: videoPath, shot: shot)
        dimensions["duration_match"] = probeResult.durationScore
        dimensions["resolution"] = probeResult.resolutionScore
        dimensions["video_codec"] = probeResult.codecScore
        dimensions["ffprobe_available"] = probeResult.ffprobeAvailable ? 100 : 0
        score += probeResult.durationScore + probeResult.resolutionScore + probeResult.codecScore
        reasons.append(contentsOf: probeResult.reasons)

        // 5. Generation succeeded (20 pts)
        var genScore: Double = 0
        if generation.status == .succeeded && generation.errorMessage == nil {
            genScore = 20
            reasons.append("Generation succeeded without errors")
        } else if generation.status == .succeeded {
            genScore = 10
            reasons.append("Generation succeeded but had warnings")
        } else {
            reasons.append("Generation status: \(generation.status.rawValue)")
        }
        dimensions["generation_status"] = genScore
        score += genScore

        let passed = score >= config.threshold

        return EvaluationResult(
            score: score,
            passed: passed,
            reasoning: reasons.joined(separator: "; "),
            evaluator: evaluatorId,
            dimensions: dimensions,
            evaluatedAt: Date()
        )
    }

    // MARK: - ffprobe

    private struct FfprobeResult {
        var durationScore: Double = 0
        var resolutionScore: Double = 0
        var codecScore: Double = 0
        var ffprobeAvailable: Bool = true
        var reasons: [String] = []
    }

    private func runFfprobe(videoPath: String, shot: Shot?) async -> FfprobeResult {
        var result = FfprobeResult()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "ffprobe", "-v", "quiet", "-print_format", "json",
            "-show_format", "-show_streams", videoPath
        ]

        let pipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errPipe
        defer {
            pipe.fileHandleForReading.closeFile()
            errPipe.fileHandleForReading.closeFile()
        }

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                result.reasons.append("ffprobe unavailable or failed (partial credit)")
                result.durationScore = 5
                result.resolutionScore = 5
                result.codecScore = 5
                result.ffprobeAvailable = false
                return result
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                result.reasons.append("ffprobe output not parseable (partial credit)")
                result.durationScore = 5
                result.resolutionScore = 5
                result.codecScore = 5
                result.ffprobeAvailable = false
                return result
            }

            // Duration match (10 pts)
            if let format = json["format"] as? [String: Any],
               let durStr = format["duration"] as? String,
               let duration = Double(durStr) {
                if let expectedDur = shot?.duration {
                    let ratio = duration / expectedDur
                    if ratio >= 0.8 && ratio <= 1.2 {
                        result.durationScore = 10
                        result.reasons.append("Duration matches expected (\(String(format: "%.1f", duration))s vs \(expectedDur)s)")
                    } else {
                        result.durationScore = 3
                        result.reasons.append("Duration mismatch (\(String(format: "%.1f", duration))s vs expected \(expectedDur)s)")
                    }
                } else {
                    // No expected duration — just check it's reasonable
                    if duration > 0.5 && duration < 300 {
                        result.durationScore = 10
                        result.reasons.append("Duration reasonable (\(String(format: "%.1f", duration))s)")
                    } else {
                        result.durationScore = 3
                        result.reasons.append("Duration unusual (\(String(format: "%.1f", duration))s)")
                    }
                }
            } else {
                result.durationScore = 0
                result.reasons.append("No duration in metadata")
            }

            // Resolution and codec from streams
            let streams = json["streams"] as? [[String: Any]] ?? []
            let videoStreams = streams.filter { ($0["codec_type"] as? String) == "video" }

            if let vs = videoStreams.first {
                // Resolution >= 720p (10 pts)
                let width = vs["width"] as? Int ?? 0
                let height = vs["height"] as? Int ?? 0
                if height >= 720 || width >= 1280 {
                    result.resolutionScore = 10
                    result.reasons.append("Resolution \(width)x\(height) (>= 720p)")
                } else if height > 0 {
                    result.resolutionScore = 5
                    result.reasons.append("Resolution \(width)x\(height) (< 720p)")
                } else {
                    result.resolutionScore = 0
                    result.reasons.append("No resolution metadata")
                }

                // Video codec present (10 pts)
                if let codec = vs["codec_name"] as? String, !codec.isEmpty {
                    result.codecScore = 10
                    result.reasons.append("Video codec: \(codec)")
                } else {
                    result.codecScore = 0
                    result.reasons.append("No video codec found")
                }
            } else {
                result.reasons.append("No video stream found")
            }

        } catch {
            result.reasons.append("ffprobe not available (partial credit)")
            result.durationScore = 5
            result.resolutionScore = 5
            result.codecScore = 5
            result.ffprobeAvailable = false
        }

        return result
    }
}
