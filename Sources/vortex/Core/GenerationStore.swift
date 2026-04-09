import Foundation
import Darwin

/// JSON-backed persistence for CLI generations.
/// Stored at ~/.vortex/store.json — readable by any agent or script.
final class GenerationStore {
    static let shared = GenerationStore()

    private let storeURL: URL
    private let lockFileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".vortex", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("store.json")
        lockFileURL = dir.appendingPathComponent("store.lock")
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
            var all = loadAll()
            all[generation.id] = generation
            persist(all)
        }
    }

    func get(_ id: String) -> CLIGeneration? {
        withFileLock {
            lock.lock(); defer { lock.unlock() }
            return loadAll()[id]
        }
    }

    func all() -> [CLIGeneration] {
        withFileLock {
            lock.lock(); defer { lock.unlock() }
            return Array(loadAll().values).sorted { $0.createdAt > $1.createdAt }
        }
    }

    func delete(_ id: String) {
        withFileLock {
            lock.lock(); defer { lock.unlock() }
            var all = loadAll()
            all.removeValue(forKey: id)
            persist(all)
        }
    }

    func update(id: String, mutate: (inout CLIGeneration) -> Void) {
        withFileLock {
            lock.lock(); defer { lock.unlock() }
            var all = loadAll()
            guard var gen = all[id] else { return }
            mutate(&gen)
            all[id] = gen
            persist(all)
        }
    }

    // MARK: - Filters

    func filter(status: CLIGeneration.GenerationStatus? = nil, provider: String? = nil, limit: Int? = nil) -> [CLIGeneration] {
        withFileLock {
            lock.lock(); defer { lock.unlock() }
            var results = Array(loadAll().values).sorted { $0.createdAt > $1.createdAt }
            if let s = status   { results = results.filter { $0.status == s } }
            if let p = provider { results = results.filter { $0.provider == p } }
            if let l = limit    { results = Array(results.prefix(l)) }
            return results
        }
    }

    // MARK: - Private

    private func loadAll() -> [String: CLIGeneration] {
        guard FileManager.default.fileExists(atPath: storeURL.path),
              let data = try? Data(contentsOf: storeURL),
              let map = try? decoder.decode([String: CLIGeneration].self, from: data) else {
            return [:]
        }
        return map
    }

    private func persist(_ map: [String: CLIGeneration]) {
        let data: Data
        do { data = try encoder.encode(map) }
        catch {
            fputs("{\"error\":\"Store encode failed: \(error.localizedDescription)\",\"code\":\"store_error\"}\n", stderr)
            return
        }
        do { try data.write(to: storeURL, options: .atomic) }
        catch {
            fputs("{\"error\":\"Store write failed: \(error.localizedDescription)\",\"code\":\"store_error\"}\n", stderr)
        }
    }
}
