import Foundation

// MARK: - Style lock (recipe format v3, consistency intent)
//
// Optional consistency extensions carried by v3 bundles. The format version
// stays 3 — "3" means "has optional extensions" and referenceImages/styleLock
// are valid in ANY v3 bundle (v3 files without them decode with nil, v2 files
// are untouched). These fields record consistency *intent*: they are exported,
// imported, and shown everywhere, and used at execution time by stages whose
// providers support image-to-video input.

/// How seeds are assigned across a stage's fanout candidates.
public enum SeedPolicy: String, Codable {
    /// One seed, reused for every candidate of the stage (reproducible look).
    case fixed
    /// Each candidate gets its own seed (provider default — more variety).
    case perShot = "per_shot"
}

/// Recorded consistency intent for a recipe: how strictly the look should be
/// locked across shots/candidates.
public struct StyleLock: Codable {
    public var seedPolicy: SeedPolicy
    public var notes: String?

    public init(seedPolicy: SeedPolicy, notes: String? = nil) {
        self.seedPolicy = seedPolicy
        self.notes = notes
    }
}
