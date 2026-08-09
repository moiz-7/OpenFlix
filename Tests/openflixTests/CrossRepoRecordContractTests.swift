import XCTest
@testable import openflix

/// **The cross-repo tripwire (plan 06 · C2-2, phase 2 · R22).**
///
/// Two features in the macOS app read files this CLI writes, across a repo
/// boundary that no build, no type checker and no CI job spans:
///
/// | App reader | File | Keys it reads |
/// |---|---|---|
/// | `GenerationDeepLinkResolver` (`OpenFlix/App/DeepLinkRoute.swift:374-376`) | `~/.openflix/generations/<id>.json` | `status`, `localPath`, `remoteVideoURL` |
/// | `CLIRunImporter` (`OpenFlix/Vortex/Services/CLIRunImporter.swift:22-38`) | `~/.openflix/runs/<id>.json` | `runId`, `kind`, `name`, `nodes`, and per node `nodeId`, `status`, `generationId`, `outputPath`; plus `id`, `provider`, `model` from the generation record |
///
/// The resolver reads with `JSONSerialization` and literal string keys; the
/// importer decodes a mirrored `Decodable` whose non-optional fields throw on
/// absence. Both depend on this CLI's `JSONEncoder` continuing to emit
/// **camelCase** — which is only true because nothing sets
/// `keyEncodingStrategy`. The day somebody adds `.convertToSnakeCase` for
/// tidiness, or renames a field, `openflix://generation/<id>` degrades to
/// "no such generation" and `Import CLI Run` degrades to an unreadable
/// journal. No error, no crash, no test failure anywhere in either repo.
///
/// So these tests deliberately do **not** round-trip through `Codable`. A
/// round-trip passes whether the key is `localPath` or `local_path`. They read
/// the bytes off disk the way the app does and assert the literal key strings.
///
/// If one of these fails, the fix is almost never "update the test" — it is
/// "the app cannot read this any more, so either revert the encoder change or
/// land the matching app change first."
final class CrossRepoRecordContractTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openflix-contract-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    private struct NotAJSONObject: Error {}

    /// Read a record back exactly the way `GenerationDeepLinkResolver` does:
    /// raw bytes → `JSONSerialization` → `[String: Any]`.
    private func rawJSON(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NotAJSONObject()
        }
        return object
    }

    private func generation(id: String) -> CLIGeneration {
        CLIGeneration(
            id: id, status: .succeeded, provider: "fal", model: "fal-ai/veo3",
            prompt: "a ceramic robot barista", negativePrompt: nil,
            aspectRatio: "16:9", widthPx: 1280, heightPx: 720, durationSeconds: 5,
            remoteTaskId: "task-1", statusURL: nil,
            remoteVideoURL: "https://example.com/v.mp4",
            localPath: "/tmp/openflix-contract/v.mp4",
            estimatedCostUSD: 0.4, actualCostUSD: 0.4, errorMessage: nil,
            retryCount: 0, createdAt: Date(), submittedAt: Date(), completedAt: Date()
        )
    }

    // MARK: - Generation record → the app's deep link

    func testGenerationRecordCarriesTheExactKeysTheAppDeepLinkReads() throws {
        let store = GenerationStore(directory: tempDir)
        let id = "contract-\(UUID().uuidString)"
        store.save(generation(id: id))

        let file = tempDir.appendingPathComponent("generations/\(id).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                      "record must land at <base>/generations/<id>.json — the path the app hardcodes")

        let json = try rawJSON(at: file)

        // DeepLinkRoute.swift:374-376 — string("status") / string("localPath") /
        // string("remoteVideoURL"). All three must be present AND be strings:
        // the reader casts, and a cast failure is indistinguishable from a
        // missing record.
        XCTAssertEqual(json["status"] as? String, "succeeded")
        XCTAssertEqual(json["localPath"] as? String, "/tmp/openflix-contract/v.mp4")
        XCTAssertEqual(json["remoteVideoURL"] as? String, "https://example.com/v.mp4")
    }

    func testGenerationRecordIsNotSnakeCased() throws {
        // The single change that would break the deep link silently.
        let store = GenerationStore(directory: tempDir)
        let id = "contract-\(UUID().uuidString)"
        store.save(generation(id: id))
        let json = try rawJSON(at: tempDir.appendingPathComponent("generations/\(id).json"))

        for snake in ["local_path", "remote_video_url", "created_at", "remote_task_id"] {
            XCTAssertNil(json[snake],
                         "'\(snake)' means keyEncodingStrategy was set to .convertToSnakeCase — "
                         + "the app's openflix://generation/<id> deep link can no longer find "
                         + "localPath/remoteVideoURL and degrades to 'no such generation'")
        }
    }

    func testGenerationRecordCarriesTheKeysTheRunImporterDecodes() throws {
        // CLIRunImporter.CLIGenerationRecord declares id/provider/model as
        // NON-optional, so any of them going missing throws at decode and the
        // whole import fails — not just the caption enrichment.
        let store = GenerationStore(directory: tempDir)
        let id = "contract-\(UUID().uuidString)"
        store.save(generation(id: id))
        let json = try rawJSON(at: tempDir.appendingPathComponent("generations/\(id).json"))

        XCTAssertEqual(json["id"] as? String, id)
        XCTAssertEqual(json["provider"] as? String, "fal")
        XCTAssertEqual(json["model"] as? String, "fal-ai/veo3")
        XCTAssertEqual(json["prompt"] as? String, "a ceramic robot barista")
    }

    func testGenerationRecordDatesAreISO8601Strings() throws {
        // Both app readers construct `JSONDecoder` with
        // `.dateDecodingStrategy = .iso8601`. Switching the CLI encoder to the
        // default (seconds since reference date) would emit a number and every
        // decode on the app side would throw.
        let store = GenerationStore(directory: tempDir)
        let id = "contract-\(UUID().uuidString)"
        store.save(generation(id: id))
        let json = try rawJSON(at: tempDir.appendingPathComponent("generations/\(id).json"))

        let created = try XCTUnwrap(json["createdAt"] as? String,
                                    "createdAt must be an ISO8601 string, not a number")
        XCTAssertNotNil(ISO8601DateFormatter().date(from: created))
    }

    func testGenerationRecordStatusUsesTheEnumRawValueTheAppSwitchesOn() throws {
        // The resolver turns a non-video record into `.notReady(status:)` and
        // shows the status verbatim. Every status the CLI can persist must
        // therefore be a stable lowercase token.
        let store = GenerationStore(directory: tempDir)
        for status in CLIGeneration.GenerationStatus.allCases {
            let id = "contract-\(UUID().uuidString)"
            var gen = generation(id: id)
            gen.status = status
            store.save(gen)
            let json = try rawJSON(at: tempDir.appendingPathComponent("generations/\(id).json"))
            XCTAssertEqual(json["status"] as? String, status.rawValue)
        }
    }

    func testGenerationRecordOmitsRatherThanNullsAnAbsentLocalPath() throws {
        // A queued generation has no file yet. The resolver's
        // `string("localPath")` cast yields nil either way, so this is about
        // keeping the record honest rather than about the reader — but a
        // record that grew a `"localPath": ""` would make `fileExists("")` the
        // deciding call instead of a clean "not ready".
        let store = GenerationStore(directory: tempDir)
        let id = "contract-\(UUID().uuidString)"
        var gen = generation(id: id)
        gen.status = .processing
        gen.localPath = nil
        gen.remoteVideoURL = nil
        store.save(gen)
        let json = try rawJSON(at: tempDir.appendingPathComponent("generations/\(id).json"))

        XCTAssertNil(json["localPath"] as? String)
        XCTAssertEqual(json["status"] as? String, "processing")
    }

    // MARK: - Proof that the guard has teeth

    func testASnakeCasedEncoderWouldBreakEveryAssertionAbove() throws {
        // A tripwire nobody has seen fire is a comment. This encodes the very
        // same record with the one-line change the tests exist to catch, and
        // shows the app's reader coming up empty — without touching the real
        // encoder, so it proves the point in isolation.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase   // the change in question
        let data = try encoder.encode(generation(id: "teeth"))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        // GenerationDeepLinkResolver reads these three and only these three.
        XCTAssertNil(json["localPath"], "snake-casing hides localPath from the deep link")
        XCTAssertNil(json["remoteVideoURL"], "snake-casing hides remoteVideoURL from the deep link")
        XCTAssertNotNil(json["local_path"], "…and puts it somewhere the app never looks")

        // `status` survives (one word), which is exactly why the failure is
        // silent: the resolver finds a record, reads a valid status, finds no
        // video, and reports "queued/running/failed" for a finished generation
        // whose file is sitting on disk.
        XCTAssertEqual(json["status"] as? String, "succeeded")
    }

    // MARK: - Run journal → the app's CLI run importer

    func testRunJournalCarriesTheExactKeysTheAppImporterDecodes() throws {
        let journal = RunJournal(directory: tempDir)
        let runId = "contract-run-\(UUID().uuidString)"
        let node = NodeRecord(nodeId: "stage1", inputsHash: "h", status: "succeeded",
                              generationId: "gen-1", outputPath: "/tmp/out.mp4",
                              costUSD: 0.4, startedAt: Date(), completedAt: Date())
        _ = journal.create(runId: runId, kind: "workflow", name: "contract",
                           projectId: nil, nodes: ["stage1": node])

        let file = tempDir.appendingPathComponent("\(runId).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                      "journal must land at <journal dir>/<run-id>.json")
        // ...and the *default* journal directory is the one the app's open
        // panel starts in (`CLIRunImporter.runsDirectory`). Constructing this
        // only reads the home directory; nothing is created until a write.
        XCTAssertTrue(RunJournal().directory.path.hasSuffix("/.openflix/runs"),
                      "the app's 'Import CLI Run' open panel defaults to ~/.openflix/runs")

        let json = try rawJSON(at: file)

        // CLIRunImporter.RunRecord: runId/kind/name/nodes, all non-optional.
        XCTAssertEqual(json["runId"] as? String, runId)
        XCTAssertEqual(json["kind"] as? String, "workflow")
        XCTAssertEqual(json["name"] as? String, "contract")

        let nodes = try XCTUnwrap(json["nodes"] as? [String: Any])
        let stage = try XCTUnwrap(nodes["stage1"] as? [String: Any])

        // CLIRunImporter.NodeRecord: nodeId/status non-optional,
        // generationId/outputPath optional but load-bearing — a node without
        // outputPath is dropped from the review session.
        XCTAssertEqual(stage["nodeId"] as? String, "stage1")
        XCTAssertEqual(stage["status"] as? String, "succeeded")
        XCTAssertEqual(stage["generationId"] as? String, "gen-1")
        XCTAssertEqual(stage["outputPath"] as? String, "/tmp/out.mp4")
    }

    func testRunJournalIsNotSnakeCased() throws {
        let journal = RunJournal(directory: tempDir)
        let runId = "contract-run-\(UUID().uuidString)"
        let node = NodeRecord(nodeId: "stage1", inputsHash: "h", status: "succeeded",
                              generationId: "gen-1", outputPath: "/tmp/out.mp4",
                              costUSD: nil, startedAt: nil, completedAt: nil)
        _ = journal.create(runId: runId, kind: "workflow", name: "contract",
                           projectId: nil, nodes: ["stage1": node])
        let json = try rawJSON(at: tempDir.appendingPathComponent("\(runId).json"))

        for snake in ["run_id", "node_id"] {
            XCTAssertNil(json[snake],
                         "'\(snake)' on disk means the app's CLIRunImporter can no longer decode "
                         + "this journal — 'Could not read the run journal'")
        }
        let nodes = try XCTUnwrap(json["nodes"] as? [String: Any])
        let stage = try XCTUnwrap(nodes["stage1"] as? [String: Any])
        XCTAssertNil(stage["node_id"])
        XCTAssertNil(stage["output_path"])
    }

    func testRunJournalNodesAreKeyedByNodeIdNotAnArray() throws {
        // `RunRecord.nodes` is `[String: NodeRecord]` on both sides. Turning
        // the journal's nodes into an array would decode-fail on the app.
        let journal = RunJournal(directory: tempDir)
        let runId = "contract-run-\(UUID().uuidString)"
        _ = journal.create(runId: runId, kind: "project", name: "c", projectId: "p",
                           nodes: ["a": NodeRecord(nodeId: "a", inputsHash: "h", status: "pending",
                                                   generationId: nil, outputPath: nil, costUSD: nil,
                                                   startedAt: nil, completedAt: nil)])
        let json = try rawJSON(at: tempDir.appendingPathComponent("\(runId).json"))
        XCTAssertNotNil(json["nodes"] as? [String: Any])
        XCTAssertNil(json["nodes"] as? [Any])
    }
}
