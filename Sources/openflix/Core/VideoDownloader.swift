import Foundation

/// Downloads videos from provider URLs to local disk.
enum VideoDownloader {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config)
    }()
    private static let downloadDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".openflix/downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Download a video from a URL. If outputURL is provided, saves there; otherwise saves
    /// to ~/.openflix/downloads/<uuid>.<ext>. Returns the local file URL.
    static func download(from remoteURL: URL, to outputURL: URL? = nil, generationId: String) async throws -> URL {
        let (tmpURL, response) = try await session.download(from: remoteURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw OpenFlixError.downloadFailed(remoteURL, "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        let ext = remoteURL.pathExtension.isEmpty ? "mp4" : remoteURL.pathExtension
        let dest = outputURL ?? downloadDir.appendingPathComponent("\(generationId).\(ext)")

        // Move atomically, overwriting existing
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        if let parent = outputURL?.deletingLastPathComponent() {
            try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try fm.moveItem(at: tmpURL, to: dest)
        return dest
    }
}
