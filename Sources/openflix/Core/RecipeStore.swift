import Foundation
import Darwin
import OpenFlixKit

// MARK: - CLI Recipe model
//
// The recipe TYPE lives in OpenFlixKit as `Recipe` (the .openflix format's
// source of truth). The CLI keeps its historical name via this typealias;
// persistence (RecipeStore below) is a CLI decision and stays here.

typealias CLIRecipe = Recipe

extension Recipe {
    /// Kit's `toExported()` plus the best-execution snapshot, which references
    /// the CLI-only CLIGeneration store model.
    func toExported(bestGen: CLIGeneration?) -> RecipeBundle.ExportedRecipe {
        var exported = toExported()
        if let gen = bestGen {
            exported.bestExecution = RecipeBundle.ExecutionSnapshot(
                provider: gen.provider, model: gen.model,
                durationSeconds: gen.durationSeconds,
                widthPx: gen.widthPx, heightPx: gen.heightPx,
                costUSD: gen.actualCostUSD ?? gen.estimatedCostUSD,
                completedAt: gen.completedAt
            )
        }
        return exported
    }
}

// MARK: - Recipe Store

/// JSON-backed persistence for CLI recipes.
/// Stored at ~/.openflix/recipes.json — readable by any agent or script.
final class RecipeStore {
    static let shared = RecipeStore()

    private let storeURL: URL          // ~/.openflix/recipes.json
    private let lockFileURL: URL       // ~/.openflix/recipes.lock
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".openflix", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("recipes.json")
        lockFileURL = dir.appendingPathComponent("recipes.lock")
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

    func save(_ recipe: CLIRecipe) {
        withFileLock {
            lock.lock(); defer { lock.unlock() }
            var all = loadAll()
            all[recipe.id] = recipe
            persist(all)
        }
    }

    func get(_ id: String) -> CLIRecipe? {
        withFileLock {
            lock.lock(); defer { lock.unlock() }
            return loadAll()[id]
        }
    }

    func all() -> [CLIRecipe] {
        withFileLock {
            lock.lock(); defer { lock.unlock() }
            return Array(loadAll().values).sorted { $0.updatedAt > $1.updatedAt }
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

    func update(id: String, mutate: (inout CLIRecipe) -> Void) {
        withFileLock {
            lock.lock(); defer { lock.unlock() }
            var all = loadAll()
            guard var recipe = all[id] else { return }
            mutate(&recipe)
            recipe.updatedAt = Date()
            all[id] = recipe
            persist(all)
        }
    }

    func search(query: String) -> [CLIRecipe] {
        let lowered = query.lowercased()
        return all().filter {
            $0.name.lowercased().contains(lowered) ||
            $0.promptText.lowercased().contains(lowered)
        }
    }

    // MARK: - Private

    private func loadAll() -> [String: CLIRecipe] {
        guard FileManager.default.fileExists(atPath: storeURL.path),
              let data = try? Data(contentsOf: storeURL),
              let map = try? decoder.decode([String: CLIRecipe].self, from: data) else {
            return [:]
        }
        return map
    }

    private func persist(_ map: [String: CLIRecipe]) {
        let data: Data
        do { data = try encoder.encode(map) }
        catch {
            fputs("{\"error\":\"Recipe store encode failed: \(error.localizedDescription)\",\"code\":\"store_error\"}\n", stderr)
            return
        }
        do { try data.write(to: storeURL, options: .atomic) }
        catch {
            fputs("{\"error\":\"Recipe store write failed: \(error.localizedDescription)\",\"code\":\"store_error\"}\n", stderr)
        }
    }
}
