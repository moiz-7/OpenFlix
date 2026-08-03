import Foundation

/// The single source of truth for the OpenFlix version string.
///
/// This used to be hardcoded in three places that could (and did) drift:
/// `OpenFlixCLI.swift` (`--version`), `MCPServer.swift` (the MCP `serverInfo`
/// handshake), and the Homebrew formula's `assert_match`. A `v1.1.0` tag would
/// have shipped a binary reporting `1.0.0`, and the formula's own test would
/// have passed only by accident.
///
/// Release checklist: bump this, tag `v<same value>`. The release workflow
/// verifies the tag matches what the built binary reports and fails otherwise,
/// so the two cannot diverge silently.
public enum OpenFlixVersion {
    public static let current = "1.0.1"
}
