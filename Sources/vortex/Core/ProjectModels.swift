import Foundation

// MARK: - Project

struct Project: Codable {
    var id: String
    var name: String
    var description: String?
    var status: ProjectStatus
    var scenes: [Scene]
    var settings: ProjectSettings
    var costBudgetUSD: Double?
    var totalEstimatedCostUSD: Double?
    var totalActualCostUSD: Double?
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?

    enum ProjectStatus: String, Codable, CaseIterable {
        case draft, running, paused, succeeded, partialFailure, failed, cancelled
    }

    var allShots: [Shot] {
        scenes.flatMap { $0.shots }
    }

    var progress: [String: Any] {
        let shots = allShots
        var counts: [String: Int] = [:]
        for s in Shot.ShotStatus.allCases { counts[s.rawValue] = 0 }
        for s in shots { counts[s.status.rawValue, default: 0] += 1 }
        var d: [String: Any] = ["total_shots": shots.count]
        for (k, v) in counts { d[k] = v }
        return d
    }

    var jsonRepresentation: [String: Any] {
        var d: [String: Any] = [
            "id": id,
            "name": name,
            "status": status.rawValue,
            "settings": settings.jsonRepresentation,
            "scenes": scenes.map { $0.jsonRepresentation },
            "progress": progress,
            "created_at": iso8601(createdAt),
            "updated_at": iso8601(updatedAt),
        ]
        if let v = description           { d["description"] = v }
        if let v = costBudgetUSD          { d["cost_budget_usd"] = round4(v) }
        if let v = totalEstimatedCostUSD  { d["total_estimated_cost_usd"] = round4(v) }
        if let v = totalActualCostUSD     { d["total_actual_cost_usd"] = round4(v) }
        if let v = completedAt            { d["completed_at"] = iso8601(v) }
        return d
    }

    private func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
    private func round4(_ v: Double) -> Double {
        (v * 10000).rounded() / 10000
    }
}

// MARK: - Project Settings

struct ProjectSettings: Codable {
    var defaultProvider: String?
    var defaultModel: String?
    var defaultAspectRatio: String?
    var defaultDuration: Double?
    var maxConcurrency: Int = 4
    var maxRetriesPerShot: Int = 2
    var timeoutPerShot: Double = 600
    var scatterCount: Int?
    var routingStrategy: RoutingStrategy = .manual
    var qualityConfig: QualityConfig = QualityConfig()

    enum RoutingStrategy: String, Codable, CaseIterable {
        case cheapest, fastest, quality, manual, scatterGather
    }

    var jsonRepresentation: [String: Any] {
        var d: [String: Any] = [
            "max_concurrency": maxConcurrency,
            "max_retries_per_shot": maxRetriesPerShot,
            "timeout_per_shot": timeoutPerShot,
            "routing_strategy": routingStrategy.rawValue,
            "quality_config": qualityConfig.jsonRepresentation,
        ]
        if let v = defaultProvider    { d["default_provider"] = v }
        if let v = defaultModel       { d["default_model"] = v }
        if let v = defaultAspectRatio { d["default_aspect_ratio"] = v }
        if let v = defaultDuration    { d["default_duration"] = v }
        if let v = scatterCount       { d["scatter_count"] = v }
        return d
    }
}

// MARK: - Scene

struct Scene: Codable {
    var id: String
    var name: String
    var description: String?
    var orderIndex: Int
    var shots: [Shot]
    var referenceAssets: [ReferenceAsset]
    var metadata: [String: String]

    var jsonRepresentation: [String: Any] {
        var d: [String: Any] = [
            "id": id,
            "name": name,
            "order_index": orderIndex,
            "shots": shots.map { $0.jsonRepresentation },
            "reference_assets": referenceAssets.map { $0.jsonRepresentation },
            "metadata": metadata,
        ]
        if let v = description { d["description"] = v }
        return d
    }
}

struct ReferenceAsset: Codable {
    var id: String
    var name: String
    var type: AssetType
    var sourceURL: String?
    var generationId: String?
    var description: String?

    enum AssetType: String, Codable {
        case characterReference, styleReference, backgroundReference, frameExtract
    }

    var jsonRepresentation: [String: Any] {
        var d: [String: Any] = [
            "id": id,
            "name": name,
            "type": type.rawValue,
        ]
        if let v = sourceURL    { d["source_url"] = v }
        if let v = generationId { d["generation_id"] = v }
        if let v = description  { d["description"] = v }
        return d
    }
}

// MARK: - Shot

struct Shot: Codable {
    var id: String
    var sceneId: String
    var name: String
    var orderIndex: Int
    var prompt: String
    var negativePrompt: String?
    var status: ShotStatus
    var provider: String?
    var model: String?
    var duration: Double?
    var aspectRatio: String?
    var width: Int?
    var height: Int?
    var referenceImageURL: String?
    var referenceAssetId: String?
    var extraParams: [String: String]
    var dependencies: [String]       // Shot IDs that must complete first
    var generationIds: [String]      // All attempts (scatter or retry)
    var selectedGenerationId: String?
    var routingDecision: String?
    var estimatedCostUSD: Double?
    var actualCostUSD: Double?
    var retryCount: Int = 0
    var maxRetries: Int?
    var errorMessage: String?
    var qualityScore: Double?
    var evaluationReasoning: String?
    var evaluationDimensions: [String: Double]?
    var qualityRetryCount: Int = 0
    var createdAt: Date
    var startedAt: Date?
    var completedAt: Date?

    enum ShotStatus: String, Codable, CaseIterable {
        case pending, ready, dispatched, processing, evaluating
        case succeeded, failed, skipped, cancelled
    }

    var jsonRepresentation: [String: Any] {
        var d: [String: Any] = [
            "id": id,
            "scene_id": sceneId,
            "name": name,
            "order_index": orderIndex,
            "prompt": prompt,
            "status": status.rawValue,
            "extra_params": extraParams,
            "dependencies": dependencies,
            "generation_ids": generationIds,
            "retry_count": retryCount,
            "created_at": iso8601(createdAt),
        ]
        if let v = negativePrompt      { d["negative_prompt"] = v }
        if let v = provider             { d["provider"] = v }
        if let v = model                { d["model"] = v }
        if let v = duration             { d["duration"] = v }
        if let v = aspectRatio          { d["aspect_ratio"] = v }
        if let v = width                { d["width"] = v }
        if let v = height               { d["height"] = v }
        if let v = referenceImageURL    { d["reference_image_url"] = v }
        if let v = referenceAssetId     { d["reference_asset_id"] = v }
        if let v = selectedGenerationId { d["selected_generation_id"] = v }
        if let v = routingDecision      { d["routing_decision"] = v }
        if let v = estimatedCostUSD     { d["estimated_cost_usd"] = round4(v) }
        if let v = actualCostUSD        { d["actual_cost_usd"] = round4(v) }
        if let v = maxRetries           { d["max_retries"] = v }
        if let v = errorMessage         { d["error_message"] = v }
        if let v = qualityScore         { d["quality_score"] = round4(v) }
        if let v = evaluationReasoning  { d["evaluation_reasoning"] = v }
        if let v = evaluationDimensions { d["evaluation_dimensions"] = v }
        if qualityRetryCount > 0        { d["quality_retry_count"] = qualityRetryCount }
        if let v = startedAt            { d["started_at"] = iso8601(v) }
        if let v = completedAt          { d["completed_at"] = iso8601(v) }
        return d
    }

    private func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
    private func round4(_ v: Double) -> Double {
        (v * 10000).rounded() / 10000
    }
}

// MARK: - Batch

struct BatchItem: Codable {
    var prompt: String
    var provider: String
    var model: String
    var negativePrompt: String?
    var duration: Double?
    var aspectRatio: String?
    var width: Int?
    var height: Int?
    var image: String?
    var extraParams: [String: String]?
    var tag: String?
}

// MARK: - Project Spec (input format for project create)

struct ProjectSpec: Codable {
    var name: String
    var description: String?
    var settings: ProjectSpecSettings?
    var scenes: [ProjectSpecScene]

    struct ProjectSpecSettings: Codable {
        var defaultProvider: String?
        var defaultModel: String?
        var defaultAspectRatio: String?
        var defaultDuration: Double?
        var maxConcurrency: Int?
        var maxRetriesPerShot: Int?
        var timeoutPerShot: Double?
        var scatterCount: Int?
        var routingStrategy: String?
        var costBudgetUsd: Double?
        var qualityEnabled: Bool?
        var qualityEvaluator: String?
        var qualityThreshold: Double?
        var qualityMaxRetries: Int?

        enum CodingKeys: String, CodingKey {
            case defaultProvider = "default_provider"
            case defaultModel = "default_model"
            case defaultAspectRatio = "default_aspect_ratio"
            case defaultDuration = "default_duration"
            case maxConcurrency = "max_concurrency"
            case maxRetriesPerShot = "max_retries_per_shot"
            case timeoutPerShot = "timeout_per_shot"
            case scatterCount = "scatter_count"
            case routingStrategy = "routing_strategy"
            case costBudgetUsd = "cost_budget_usd"
            case qualityEnabled = "quality_enabled"
            case qualityEvaluator = "quality_evaluator"
            case qualityThreshold = "quality_threshold"
            case qualityMaxRetries = "quality_max_retries"
        }
    }

    struct ProjectSpecScene: Codable {
        var name: String
        var description: String?
        var orderIndex: Int?
        var referenceAssets: [ProjectSpecAsset]?
        var shots: [ProjectSpecShot]

        enum CodingKeys: String, CodingKey {
            case name, description, shots
            case orderIndex = "order_index"
            case referenceAssets = "reference_assets"
        }
    }

    struct ProjectSpecAsset: Codable {
        var name: String
        var type: String
        var sourceUrl: String?
        var description: String?

        enum CodingKeys: String, CodingKey {
            case name, type, description
            case sourceUrl = "source_url"
        }
    }

    struct ProjectSpecShot: Codable {
        var name: String
        var prompt: String
        var negativePrompt: String?
        var provider: String?
        var model: String?
        var duration: Double?
        var aspectRatio: String?
        var width: Int?
        var height: Int?
        var referenceImageUrl: String?
        var referenceAssetName: String?
        var extraParams: [String: String]?
        var dependencies: [String]?
        var orderIndex: Int?
        var maxRetries: Int?

        enum CodingKeys: String, CodingKey {
            case name, prompt, provider, model, duration, width, height, dependencies
            case negativePrompt = "negative_prompt"
            case aspectRatio = "aspect_ratio"
            case referenceImageUrl = "reference_image_url"
            case referenceAssetName = "reference_asset_name"
            case extraParams = "extra_params"
            case orderIndex = "order_index"
            case maxRetries = "max_retries"
        }
    }
}
