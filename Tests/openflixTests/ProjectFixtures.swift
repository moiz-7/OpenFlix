import Foundation
@testable import openflix

/// Shared builders for project/scene/shot graphs used by the DAG executor tests.
///
/// `ProjectStore` is a hard singleton (`private init`) writing under
/// `~/.openflix/projects/`, and `FileManager.homeDirectoryForCurrentUser`
/// ignores `$HOME`, so shell isolation cannot redirect it. Tests therefore use
/// the real store with a per-test UUID project id and delete it in teardown —
/// the same approach `test.sh` takes for recipes.
enum ProjectFixtures {

    static func shot(
        id: String,
        name: String? = nil,
        deps: [String] = [],
        order: Int = 0,
        status: Shot.ShotStatus = .pending,
        provider: String? = nil,
        model: String? = nil,
        duration: Double? = nil,
        estimatedCostUSD: Double? = nil,
        actualCostUSD: Double? = nil,
        fanout: Int? = nil
    ) -> Shot {
        Shot(
            id: id, sceneId: "scene-1", name: name ?? id, orderIndex: order,
            prompt: "a test prompt", negativePrompt: nil, status: status,
            provider: provider, model: model, duration: duration,
            aspectRatio: nil, width: nil, height: nil,
            referenceImageURL: nil, referenceAssetId: nil, extraParams: [:],
            dependencies: deps, generationIds: [], selectedGenerationId: nil,
            routingDecision: nil, estimatedCostUSD: estimatedCostUSD,
            actualCostUSD: actualCostUSD, maxRetries: nil, errorMessage: nil,
            qualityScore: nil, evaluationReasoning: nil, evaluationDimensions: nil,
            createdAt: Date(), startedAt: nil, completedAt: nil,
            fanout: fanout
        )
    }

    static func project(
        id: String,
        shots: [Shot],
        settings: ProjectSettings = ProjectSettings(),
        costBudgetUSD: Double? = nil
    ) -> Project {
        let scene = Scene(
            id: "scene-1", name: "scene one", description: nil, orderIndex: 0,
            shots: shots, referenceAssets: [], metadata: [:]
        )
        return Project(
            id: id, name: "fixture", description: nil, status: .draft,
            scenes: shots.isEmpty ? [] : [scene],
            settings: settings, costBudgetUSD: costBudgetUSD,
            totalEstimatedCostUSD: nil, totalActualCostUSD: nil,
            createdAt: Date(), updatedAt: Date(), completedAt: nil
        )
    }

    /// A provider id that is guaranteed not to be in `ProviderRegistry`, so no
    /// key lookup, no HTTP request and no billing can possibly happen if a code
    /// path ever reaches `GenerationEngine.submit` from one of these fixtures.
    static let unroutableProvider = "openflix-test-nonexistent-provider"
    static let unroutableModel = "openflix-test-nonexistent-model"
}
