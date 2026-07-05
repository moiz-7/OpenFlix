import XCTest
@testable import openflix

final class GenerationStoreTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openflix-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeGen(id: String, provider: String = "fal",
                         status: CLIGeneration.GenerationStatus = .succeeded,
                         createdAt: Date = Date()) -> CLIGeneration {
        CLIGeneration(
            id: id, status: status, provider: provider, model: "fal-ai/veo3",
            prompt: "p", negativePrompt: nil, aspectRatio: nil,
            widthPx: nil, heightPx: nil, durationSeconds: 4,
            remoteTaskId: nil, statusURL: nil, remoteVideoURL: nil, localPath: nil,
            estimatedCostUSD: 0.2, actualCostUSD: nil, errorMessage: nil,
            retryCount: 0, projectId: nil, shotId: nil,
            createdAt: createdAt, submittedAt: nil, completedAt: nil
        )
    }

    // MARK: - Per-record CRUD

    func testSaveGetUpdateDeleteRoundtrip() {
        let store = GenerationStore(directory: dir)
        store.save(makeGen(id: "g1"))

        // One file per record, mirroring ProjectStore's layout
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("generations/g1.json").path))

        XCTAssertEqual(store.get("g1")?.prompt, "p")
        store.update(id: "g1") { $0.actualCostUSD = 0.5 }
        XCTAssertEqual(store.get("g1")?.actualCostUSD, 0.5)

        store.delete("g1")
        XCTAssertNil(store.get("g1"))
        XCTAssertTrue(store.all().isEmpty)
    }

    func testAllSortsNewestFirstAndFilterWorks() {
        let store = GenerationStore(directory: dir)
        store.save(makeGen(id: "old", createdAt: Date(timeIntervalSince1970: 1000)))
        store.save(makeGen(id: "new", provider: "luma", status: .failed,
                           createdAt: Date(timeIntervalSince1970: 2000)))

        XCTAssertEqual(store.all().map(\.id), ["new", "old"])
        XCTAssertEqual(store.filter(status: .failed).map(\.id), ["new"])
        XCTAssertEqual(store.filter(provider: "fal").map(\.id), ["old"])
        XCTAssertEqual(store.filter(limit: 1).count, 1)
    }

    // MARK: - Legacy single-file migration

    private func writeLegacyStore(_ gens: [CLIGeneration]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let map = Dictionary(uniqueKeysWithValues: gens.map { ($0.id, $0) })
        try encoder.encode(map).write(to: dir.appendingPathComponent("store.json"))
    }

    func testLegacyStoreMigratesOnFirstAccess() throws {
        try writeLegacyStore([makeGen(id: "a"), makeGen(id: "b", provider: "luma")])

        let store = GenerationStore(directory: dir)
        let all = store.all()   // first access triggers migration
        XCTAssertEqual(Set(all.map(\.id)), ["a", "b"])

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("generations/a.json").path))
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("generations/b.json").path))
        // Legacy file renamed (kept as backup), so migration runs exactly once
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("store.json").path))
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("store.json.migrated").path))

        // Records fully usable through the public API after migration
        XCTAssertEqual(store.get("b")?.provider, "luma")
    }

    func testMigrationDoesNotClobberNewerPerRecordFiles() throws {
        // A per-record file already exists (e.g. written by a newer process);
        // the legacy copy of the same id must not overwrite it.
        let store = GenerationStore(directory: dir)
        var updated = makeGen(id: "a")
        updated.actualCostUSD = 9.9
        store.save(updated)

        try writeLegacyStore([makeGen(id: "a"), makeGen(id: "c")])
        let fresh = GenerationStore(directory: dir)   // new instance re-checks migration
        XCTAssertEqual(fresh.get("a")?.actualCostUSD, 9.9)
        XCTAssertNotNil(fresh.get("c"))
    }

    func testCorruptLegacyStoreIsLeftUntouched() throws {
        try Data("not json".utf8).write(to: dir.appendingPathComponent("store.json"))
        let store = GenerationStore(directory: dir)
        XCTAssertTrue(store.all().isEmpty)
        // Never silently discarded
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("store.json").path))
    }

    func testNoLegacyFileNoMigrationArtifacts() {
        let store = GenerationStore(directory: dir)
        _ = store.all()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("store.json.migrated").path))
    }
}
