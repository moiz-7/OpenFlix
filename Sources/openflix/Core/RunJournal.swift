import Foundation
import CryptoKit

// MARK: - Run journal records

/// Reference intent for a node: which upstream stage feeds its output forward
/// as the I2V reference, and what it resolved to at execution time (null until
/// the upstream node has produced an output — e.g. in freshly created runs).
struct NodeReferenceRecord: Codable {
    var from: String              // upstream stage id (reference_from)
    var resolvedPath: String?     // upstream output URL/path, once known

    enum CodingKeys: String, CodingKey {
        case from
        case resolvedPath = "resolved_path"
    }

    var jsonRepresentation: [String: Any] {
        ["from": from, "resolved_path": resolvedPath ?? NSNull()]
    }
}

/// One record per executed node (shot/stage) in a DAG run.
struct NodeRecord: Codable {
    var nodeId: String            // stable node key (shot/stage name)
    var inputsHash: String        // stable hash of the node spec
    var status: String            // pending, succeeded, failed, skipped
    var generationId: String?     // selected generation (best candidate)
    var outputPath: String?       // local video path when downloaded
    var costUSD: Double?
    var startedAt: Date?
    var completedAt: Date?
    var reference: NodeReferenceRecord? = nil   // reference_from intent + resolution

    var jsonRepresentation: [String: Any] {
        var d: [String: Any] = [
            "node_id": nodeId,
            "inputs_hash": inputsHash,
            "status": status,
        ]
        if let v = generationId { d["generation_id"] = v }
        if let v = outputPath   { d["output_path"] = v }
        if let v = costUSD      { d["cost_usd"] = (v * 10000).rounded() / 10000 }
        if let v = startedAt    { d["started_at"] = ISO8601DateFormatter().string(from: v) }
        if let v = completedAt  { d["completed_at"] = ISO8601DateFormatter().string(from: v) }
        if let v = reference    { d["reference"] = v.jsonRepresentation }
        return d
    }
}

/// Journal of one DAG/project/workflow execution.
struct RunRecord: Codable {
    var runId: String
    var kind: String              // "workflow" or "project"
    var name: String
    var projectId: String?
    var createdAt: Date
    var updatedAt: Date
    var nodes: [String: NodeRecord]   // keyed by nodeId
}

// MARK: - Run journal store

/// Incremental, atomic journal at ~/.openflix/runs/<run-id>.json.
/// Every write is write-temp-rename (Data .atomic). Directory is injectable
/// for tests; defaults to ~/.openflix/runs.
final class RunJournal {
    let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    init(directory: URL? = nil) {
        self.directory = directory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".openflix/runs", isDirectory: true)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    private func fileURL(_ runId: String) -> URL {
        directory.appendingPathComponent("\(runId).json")
    }

    func create(runId: String, kind: String, name: String, projectId: String?, nodes: [String: NodeRecord]) -> RunRecord {
        let record = RunRecord(
            runId: runId, kind: kind, name: name, projectId: projectId,
            createdAt: Date(), updatedAt: Date(), nodes: nodes
        )
        persist(record)
        return record
    }

    func load(runId: String) -> RunRecord? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL(runId)) else { return nil }
        return try? decoder.decode(RunRecord.self, from: data)
    }

    /// Incremental write: upsert one node record and persist atomically.
    func upsertNode(runId: String, _ node: NodeRecord) {
        lock.lock(); defer { lock.unlock() }
        guard var record = (try? Data(contentsOf: fileURL(runId)))
            .flatMap({ try? decoder.decode(RunRecord.self, from: $0) }) else { return }
        record.nodes[node.nodeId] = node
        record.updatedAt = Date()
        persistLocked(record)
    }

    func save(_ record: RunRecord) {
        persist(record)
    }

    private func persist(_ record: RunRecord) {
        lock.lock(); defer { lock.unlock() }
        persistLocked(record)
    }

    private func persistLocked(_ record: RunRecord) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(record) else {
            fputs("{\"error\":\"Run journal encode failed\",\"code\":\"journal_error\"}\n", stderr)
            return
        }
        // .atomic = write to a temp file, then rename over the target.
        do { try data.write(to: fileURL(record.runId), options: .atomic) }
        catch {
            fputs("{\"error\":\"Run journal write failed: \(error.localizedDescription)\",\"code\":\"journal_error\"}\n", stderr)
        }
    }

    // MARK: - Inputs hash

    /// Stable hash of a node spec: canonical JSON (sorted keys) → SHA256 hex.
    /// Key order in the input dictionary never affects the result.
    static func inputsHash(_ spec: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(spec),
              let data = try? JSONSerialization.data(withJSONObject: spec, options: [.sortedKeys]) else {
            return "invalid-spec"
        }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Inputs hash for a Shot (used by project runs).
    static func inputsHash(for shot: Shot) -> String {
        var spec: [String: Any] = [
            "prompt": shot.prompt,
            "extra_params": shot.extraParams,
            "dependencies": shot.dependencies.sorted(),
        ]
        if let v = shot.negativePrompt    { spec["negative_prompt"] = v }
        if let v = shot.provider          { spec["provider"] = v }
        if let v = shot.model             { spec["model"] = v }
        if let v = shot.duration          { spec["duration"] = v }
        if let v = shot.aspectRatio       { spec["aspect_ratio"] = v }
        if let v = shot.width             { spec["width"] = v }
        if let v = shot.height            { spec["height"] = v }
        if let v = shot.referenceImageURL { spec["reference_image_url"] = v }
        if let v = shot.fanout            { spec["fanout"] = v }
        if let j = shot.judge {
            var jd: [String: Any] = ["keep": j.keep]
            if let m = j.minScore { jd["min_score"] = m }
            spec["judge"] = jd
        }
        return inputsHash(spec)
    }
}

// MARK: - Resume decision (pure)

enum ResumePolicy {
    /// A node is skipped on resume only when the prior run completed it
    /// successfully AND its inputs are unchanged. Failed, pending, or
    /// changed nodes re-execute.
    static func shouldSkip(prior: NodeRecord?, currentHash: String) -> Bool {
        guard let prior else { return false }
        return prior.status == "succeeded" && prior.inputsHash == currentHash
    }
}
