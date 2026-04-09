import Foundation

/// One-time migration of data directory from ~/.vortex/ to ~/.openflix/.
enum DataMigration {
    private static let migrationFlag = "com.openflix.cli.data.migrated"

    /// Migrate ~/.vortex/ to ~/.openflix/ if needed.
    /// - Safe to call multiple times (guarded by UserDefaults flag).
    /// - Skips if ~/.openflix/ already exists.
    /// - On failure: logs warning to stderr, does not crash.
    static func migrateDataDirectoryIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migrationFlag) else { return }
        defer { UserDefaults.standard.set(true, forKey: migrationFlag) }

        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let oldDir = home.appendingPathComponent(".vortex", isDirectory: true)
        let newDir = home.appendingPathComponent(".openflix", isDirectory: true)

        // If new directory already exists, nothing to do
        guard !fm.fileExists(atPath: newDir.path) else { return }

        // If old directory doesn't exist, nothing to migrate
        guard fm.fileExists(atPath: oldDir.path) else { return }

        // Move old -> new
        do {
            try fm.moveItem(at: oldDir, to: newDir)
        } catch {
            fputs("{\"warning\":\"Data migration failed (~/.vortex -> ~/.openflix): \(error.localizedDescription)\",\"code\":\"migration_warning\"}\n", stderr)
        }
    }
}
