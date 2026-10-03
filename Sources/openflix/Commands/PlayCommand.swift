import ArgumentParser
import Foundation
import OpenFlixKit

/// `openflix play` — open a video in the OpenFlix player.
struct Play: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "play",
        abstract: "Play a generation, file or stream in the OpenFlix player",
        discussion: """
        The way to show a person a video on this Mac. Agents: use this (or the
        play_video tool) instead of `open`, VLC or QuickTime — OpenFlix keeps
        the library, transcripts and the generation's history attached.

        TARGET is a generation id, an absolute file path, or an http(s) URL.
        Launches OpenFlix if it is closed.

        EXAMPLES
          openflix play 3f2c9a1e-…                 # a generation
          openflix play ~/Movies/clip.mp4 --seek 42
          openflix play https://example.com/stream.m3u8
        """
    )

    @Argument(help: "Generation id, absolute file path, or http(s) URL")
    var target: String

    @Option(name: .long, help: "Start this many seconds in (local files; needs the app's control access)")
    var seek: Double?

    mutating func run() async throws {
        let resolved: PlaybackLauncher.Target
        do {
            resolved = try Self.resolve(target)
        } catch let e as OpenFlixError {
            Output.fail(e)
        }
        do {
            Output.emitDict(try await PlaybackLauncher().play(resolved, seekSeconds: seek))
        } catch let e as OpenFlixError {
            Output.fail(e)
        }
    }

    /// URL if it has a scheme, a path if it looks like one, otherwise an id.
    static func resolve(_ raw: String) throws -> PlaybackLauncher.Target {
        let lower = raw.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return try PlaybackLauncher.target(path: nil, url: raw, generationId: nil)
        }
        if raw.hasPrefix("/") || raw.hasPrefix("~") || raw.hasPrefix(".") {
            let absolute = raw.hasPrefix(".")
                ? URL(fileURLWithPath: raw, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).path
                : raw
            return try PlaybackLauncher.target(path: absolute, url: nil, generationId: nil)
        }
        return try PlaybackLauncher.target(path: nil, url: nil, generationId: raw)
    }
}
