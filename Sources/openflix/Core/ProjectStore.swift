import Foundation
import Darwin

/// File-locked persistence for projects.
/// Stored at ~/.openflix/projects/<project-id>/project.json
final class ProjectStore {
    static let shared = ProjectStore()

    private let baseDir: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        baseDir = home.appendingPathComponent(".openflix/projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - File lock (per-project)

    private func projectDir(_ id: String) -> URL {
        baseDir.appendingPathComponent(id, isDirectory: true)
    }

    private func projectFile(_ id: String) -> URL {
        projectDir(id).appendingPathComponent("project.json")
    }

    private func lockFile(_ id: String) -> URL {
        projectDir(id).appendingPathComponent("project.lock")
    }

    private func withFileLock<T>(projectId: String, _ body: () throws -> T) rethrows -> T {
        let dir = projectDir(projectId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(lockFile(projectId).path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return try body() }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN); close(fd) }
        return try body()
    }

    // MARK: - CRUD

    func save(_ project: Project) {
        withFileLock(projectId: project.id) {
            lock.lock(); defer { lock.unlock() }
            persist(project)
        }
    }

    func get(_ id: String) -> Project? {
        withFileLock(projectId: id) {
            lock.lock(); defer { lock.unlock() }
            return load(id)
        }
    }

    func list() -> [Project] {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: baseDir, includingPropertiesForKeys: nil
        ) else { return [] }

        var projects: [Project] = []
        for dir in contents {
            let file = dir.appendingPathComponent("project.json")
            guard fm.fileExists(atPath: file.path),
                  let data = try? Data(contentsOf: file),
                  let project = try? decoder.decode(Project.self, from: data) else { continue }
            projects.append(project)
        }
        return projects.sorted { $0.createdAt > $1.createdAt }
    }

    func delete(_ id: String) {
        withFileLock(projectId: id) {
            lock.lock(); defer { lock.unlock() }
            let dir = projectDir(id)
            try? FileManager.default.removeItem(at: dir)
        }
    }

    func update(id: String, mutate: (inout Project) -> Void) {
        withFileLock(projectId: id) {
            lock.lock(); defer { lock.unlock() }
            guard var project = load(id) else { return }
            mutate(&project)
            project.updatedAt = Date()
            persist(project)
        }
    }

    // MARK: - Shot-level convenience

    func updateShot(projectId: String, shotId: String, mutate: (inout Shot) -> Void) {
        update(id: projectId) { project in
            for si in project.scenes.indices {
                for shi in project.scenes[si].shots.indices {
                    if project.scenes[si].shots[shi].id == shotId {
                        mutate(&project.scenes[si].shots[shi])
                        return
                    }
                }
            }
        }
    }

    // MARK: - Private

    private func load(_ id: String) -> Project? {
        let file = projectFile(id)
        guard FileManager.default.fileExists(atPath: file.path),
              let data = try? Data(contentsOf: file),
              let project = try? decoder.decode(Project.self, from: data) else {
            return nil
        }
        return project
    }

    private func persist(_ project: Project) {
        let dir = projectDir(project.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data: Data
        do { data = try encoder.encode(project) }
        catch {
            fputs("{\"error\":\"Project encode failed: \(error.localizedDescription)\",\"code\":\"store_error\"}\n", stderr)
            return
        }
        do { try data.write(to: projectFile(project.id), options: .atomic) }
        catch {
            fputs("{\"error\":\"Project write failed: \(error.localizedDescription)\",\"code\":\"store_error\"}\n", stderr)
        }
    }

    // MARK: - Spec → Project conversion

    static func createFromSpec(_ spec: ProjectSpec) throws -> Project {
        let projectId = UUID().uuidString

        // Build name → shot ID map for dependency resolution
        var shotNameToId: [String: String] = [:]
        for scene in spec.scenes {
            for shot in scene.shots {
                let shotId = UUID().uuidString
                if shotNameToId[shot.name] != nil {
                    throw ProjectSpecError.duplicateShotName(shot.name)
                }
                shotNameToId[shot.name] = shotId
            }
        }

        // Build settings
        var settings = ProjectSettings()
        if let s = spec.settings {
            settings.defaultProvider = s.defaultProvider
            settings.defaultModel = s.defaultModel
            settings.defaultAspectRatio = s.defaultAspectRatio
            settings.defaultDuration = s.defaultDuration
            if let v = s.maxConcurrency     { settings.maxConcurrency = v }
            if let v = s.maxRetriesPerShot  { settings.maxRetriesPerShot = v }
            if let v = s.timeoutPerShot     { settings.timeoutPerShot = v }
            settings.scatterCount = s.scatterCount
            if let v = s.routingStrategy,
               let strategy = ProjectSettings.RoutingStrategy(rawValue: v) {
                settings.routingStrategy = strategy
            }
            if let v = s.qualityEnabled   { settings.qualityConfig.enabled = v }
            if let v = s.qualityEvaluator,
               let e = QualityConfig.EvaluatorType(rawValue: v) {
                settings.qualityConfig.evaluator = e
            }
            if let v = s.qualityThreshold  { settings.qualityConfig.threshold = v }
            if let v = s.qualityMaxRetries { settings.qualityConfig.maxRetries = v }
        }

        let now = Date()
        var scenes: [Scene] = []

        for (sceneIdx, specScene) in spec.scenes.enumerated() {
            let sceneId = UUID().uuidString

            // Reference assets
            let assets: [ReferenceAsset] = (specScene.referenceAssets ?? []).map { a in
                ReferenceAsset(
                    id: UUID().uuidString,
                    name: a.name,
                    type: ReferenceAsset.AssetType(rawValue: a.type) ?? .characterReference,
                    sourceURL: a.sourceUrl,
                    generationId: nil,
                    description: a.description
                )
            }

            // Shots
            var shots: [Shot] = []
            for (shotIdx, specShot) in specScene.shots.enumerated() {
                let shotId = shotNameToId[specShot.name]!

                // Resolve dependency names → IDs
                let depIds: [String] = (specShot.dependencies ?? []).compactMap { depName in
                    guard let depId = shotNameToId[depName] else {
                        fputs("{\"warning\":\"Unknown dependency '\(depName)' in shot '\(specShot.name)'\"}\n", stderr)
                        return nil
                    }
                    return depId
                }

                shots.append(Shot(
                    id: shotId,
                    sceneId: sceneId,
                    name: specShot.name,
                    orderIndex: specShot.orderIndex ?? shotIdx,
                    prompt: specShot.prompt,
                    negativePrompt: specShot.negativePrompt,
                    status: .pending,
                    provider: specShot.provider,
                    model: specShot.model,
                    duration: specShot.duration,
                    aspectRatio: specShot.aspectRatio,
                    width: specShot.width,
                    height: specShot.height,
                    referenceImageURL: specShot.referenceImageUrl,
                    referenceAssetId: nil,
                    extraParams: specShot.extraParams ?? [:],
                    dependencies: depIds,
                    generationIds: [],
                    selectedGenerationId: nil,
                    routingDecision: nil,
                    estimatedCostUSD: nil,
                    actualCostUSD: nil,
                    retryCount: 0,
                    maxRetries: specShot.maxRetries,
                    errorMessage: nil,
                    qualityScore: nil,
                    evaluationReasoning: nil,
                    evaluationDimensions: nil,
                    qualityRetryCount: 0,
                    createdAt: now,
                    startedAt: nil,
                    completedAt: nil
                ))
            }

            scenes.append(Scene(
                id: sceneId,
                name: specScene.name,
                description: specScene.description,
                orderIndex: specScene.orderIndex ?? sceneIdx,
                shots: shots,
                referenceAssets: assets,
                metadata: [:]
            ))
        }

        let project = Project(
            id: projectId,
            name: spec.name,
            description: spec.description,
            status: .draft,
            scenes: scenes,
            settings: settings,
            costBudgetUSD: spec.settings?.costBudgetUsd,
            totalEstimatedCostUSD: nil,
            totalActualCostUSD: nil,
            createdAt: now,
            updatedAt: now,
            completedAt: nil
        )

        // Validate DAG (no cycles)
        try DAGResolver.validateNoCycles(shots: project.allShots)

        return project
    }
}

enum ProjectSpecError: Error, LocalizedError {
    case duplicateShotName(String)
    case cyclicDependency(String)
    case invalidSpec(String)

    var errorDescription: String? {
        switch self {
        case .duplicateShotName(let n): return "Duplicate shot name: '\(n)'"
        case .cyclicDependency(let m):  return "Cyclic dependency detected: \(m)"
        case .invalidSpec(let m):       return "Invalid project spec: \(m)"
        }
    }

    var code: String {
        switch self {
        case .duplicateShotName: return "duplicate_shot_name"
        case .cyclicDependency:  return "cyclic_dependency"
        case .invalidSpec:       return "invalid_spec"
        }
    }
}
