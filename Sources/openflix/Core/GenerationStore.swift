import Foundation
import Darwin

/// JSON-backed persistence for CLI generations.
/// One file per record at ~/.openflix/generations/<id>.json — readable by any
/// agent or script, and a save/update rewrites one small file instead of the
/// whole history (mirrors ProjectStore's per-record layout).
///
/// The legacy single-file layout (~/.openflix/store.json) is migrated
/// transparently on first access; the old file is kept as store.json.migrated.
final class GenerationStore {
    static let shared = GenerationStore()

    private let recordsDir: URL        // ~/.openflix/generations/
    private let legacyStoreURL: URL    // ~/.openflix/store.json (pre-migration)
    private let lockFileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()
    private var checkedLegacyMigration = false

    /// Directory is injectable for tests; defaults to ~/.openflix.
    init(directory: URL? = nil) {
        if directory == nil {
            // Migrate ~/.vortex/ → ~/.openflix/ on first launch (idempotent)
            DataMigration.migrateDataDirectoryIfNeeded()
        }
        let base = directory
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openflix", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        recordsDir = base.appendingPathComponent("generations", isDirectory: true)
        legacyStoreURL = base.appendingPathComponent("store.json")
        lockFileURL = base.appendingPathComponent("store.lock")
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - File lock

    private func withFileLock<T>(_ body: () throws -> T) rethrows -> T {
        let fd = open(lockFileURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return try body() }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN); close(fd) }
        return try body()
    }

    // MARK: - CRUD

    func save(_ generation: CLIGeneration) {
        withFileLock {
            lock.lock(); defer { lock.unlock() }
            migrateLegacyIfNeeded()
            persistRecord(generation)
        }
    }

    func get(_ id: String) -> CLIGeneration? {
        withFileLock {
            lock.lock(); defer { lock.unlock() }
            migrateLegacyIfNeeded()
            return loadRecord(id)
        }
    }

    func all() -> [CLIGeneration] {
        withFileLock {
            lock.lock(); defer { lock.unlock() }
            migrateLegacyIfNeeded()
            return loadAllRecords().sorted { $0.createdAt > $1.createdAt }
        }
    }

    func delete(_ id: String) {
        withFileLock {
            lock.lock(); defer { lock.unlock() }
            migrateLegacyIfNeeded()
            try? FileManager.default.removeItem(at: recordFile(id))
        }
    }

    func update(id: String, mutate: (inout CLIGeneration) -> Void) {
        withFileLock {
            lock.lock(); defer { lock.unlock() }
            migrateLegacyIfNeeded()
            guard var gen = loadRecord(id) else { return }
            mutate(&gen)
            persistRecord(gen)
        }
    }

    // MARK: - Filters

    func filter(status: CLIGeneration.GenerationStatus? = nil, provider: String? = nil, limit: Int? = nil) -> [CLIGeneration] {
        withFileLock {
            lock.lock(); defer { lock.unlock() }
            migrateLegacyIfNeeded()
            var results = loadAllRecords().sorted { $0.createdAt > $1.createdAt }
            if let s = status   { results = results.filter { $0.status == s } }
            if let p = provider { results = results.filter { $0.provider == p } }
            if let l = limit    { results = Array(results.prefix(l)) }
            return results
        }
    }

    // MARK: - Legacy migration (single store.json → per-record files)

    /// One-time, idempotent, and cross-process safe (always called under the
    /// file lock). On decode failure the legacy file is left in place and a
    /// warning is emitted — never silently discarded.
    private func migrateLegacyIfNeeded() {
        guard !checkedLegacyMigration else { return }
        checkedLegacyMigration = true
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyStoreURL.path) else { return }

        guard let data = try? Data(contentsOf: legacyStoreURL),
              let map = try? decoder.decode([String: CLIGeneration].self, from: data) else {
            fputs("{\"warning\":\"Legacy store.json could not be decoded; leaving it untouched\",\"code\":\"store_migration_skipped\"}\n", stderr)
            return
        }
        try? fm.createDirectory(at: recordsDir, withIntermediateDirectories: true)
        for (id, gen) in map where !fm.fileExists(atPath: recordFile(id).path) {
            persistRecord(gen)
        }
        // Keep the original as a backup so migration runs exactly once.
        let backup = legacyStoreURL.appendingPathExtension("migrated")
        try? fm.removeItem(at: backup)
        try? fm.moveItem(at: legacyStoreURL, to: backup)
    }

    // MARK: - Private

    private func recordFile(_ id: String) -> URL {
        recordsDir.appendingPathComponent("\(id).json")
    }

    private func loadRecord(_ id: String) -> CLIGeneration? {
        let file = recordFile(id)
        guard FileManager.default.fileExists(atPath: file.path),
              let data = try? Data(contentsOf: file),
              let gen = try? decoder.decode(CLIGeneration.self, from: data) else {
            return nil
        }
        return gen
    }

    private func loadAllRecords() -> [CLIGeneration] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: recordsDir, includingPropertiesForKeys: nil) else {
            return []
        }
        var generations: [CLIGeneration] = []
        for file in contents where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let gen = try? decoder.decode(CLIGeneration.self, from: data) else { continue }
            generations.append(gen)
        }
        return generations
    }

    private func persistRecord(_ generation: CLIGeneration) {
        try? FileManager.default.createDirectory(at: recordsDir, withIntermediateDirectories: true)
        let data: Data
        do { data = try encoder.encode(generation) }
        catch {
            fputs("{\"error\":\"Store encode failed: \(error.localizedDescription)\",\"code\":\"store_error\"}\n", stderr)
            return
        }
        do { try data.write(to: recordFile(generation.id), options: .atomic) }
        catch {
            fputs("{\"error\":\"Store write failed: \(error.localizedDescription)\",\"code\":\"store_error\"}\n", stderr)
        }
    }
}
