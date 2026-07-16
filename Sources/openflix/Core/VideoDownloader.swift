import Foundation

/// Downloads videos from provider URLs to local disk.
enum VideoDownloader {
    /// Hard ceiling on a downloaded video — a misbehaving/compromised provider
    /// URL must not be able to stream unbounded bytes to local disk.
    private static let maxBytes: Int64 = 4 * 1024 * 1024 * 1024 // 4 GB
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
        let (tmpURL, response) = try await session.download(from: remoteURL, delegate: SizeGuardDelegate(maxBytes: maxBytes))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw OpenFlixError.downloadFailed(remoteURL, "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        // Reject an oversized body even if the progress callback didn't fire
        // (no Content-Length + a small overrun).
        let fm = FileManager.default
        if let size = try? fm.attributesOfItem(atPath: tmpURL.path)[.size] as? Int64, size > maxBytes {
            try? fm.removeItem(at: tmpURL)
            throw OpenFlixError.downloadFailed(remoteURL, "response exceeds \(maxBytes)-byte size cap")
        }

        let ext = remoteURL.pathExtension.isEmpty ? "mp4" : remoteURL.pathExtension
        let dest = outputURL ?? downloadDir.appendingPathComponent("\(generationId).\(ext)")

        if let parent = outputURL?.deletingLastPathComponent() {
            try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        // Non-destructive replace: `replaceItemAt` preserves the existing file if
        // the swap fails (the old code deleted dest FIRST, so a failed cross-volume
        // move destroyed a previously-good file).
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: tmpURL)
        } else {
            try fm.moveItem(at: tmpURL, to: dest)
        }
        return dest
    }
}

/// Cancels a download once it exceeds the byte ceiling.
private final class SizeGuardDelegate: NSObject, URLSessionDownloadDelegate {
    private let maxBytes: Int64
    init(maxBytes: Int64) { self.maxBytes = maxBytes }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > maxBytes || totalBytesWritten > maxBytes {
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
