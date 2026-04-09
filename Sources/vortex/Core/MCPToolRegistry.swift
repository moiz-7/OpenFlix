import Foundation

/// Registry of all MCP tools and resources exposed by Vortex.
enum MCPToolRegistry {

    // MARK: - Tools

    static let allTools: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: "generate",
            description: "Submit a video generation request, poll until complete, and download the result. Returns the full generation object.",
            inputSchema: objectSchema(
                required: ["prompt", "provider", "model"],
                properties: [
                    "prompt": stringProp("Text prompt describing the video to generate"),
                    "provider": stringProp("Provider ID (fal, replicate, runway, luma, kling, minimax)"),
                    "model": stringProp("Model ID (provider-specific)"),
                    "negative_prompt": stringProp("Negative prompt (what to avoid)"),
                    "width": intProp("Video width in pixels"),
                    "height": intProp("Video height in pixels"),
                    "duration_seconds": numberProp("Video duration in seconds"),
                    "aspect_ratio": stringProp("Aspect ratio (e.g. 16:9, 9:16)"),
                    "timeout": numberProp("Timeout in seconds (default 300)"),
                    "max_retries": intProp("Max retry attempts on failure (default 0)"),
                ]
            )
        ),
        MCPToolDefinition(
            name: "generate_submit",
            description: "Submit a video generation request without waiting. Returns generation ID for later polling.",
            inputSchema: objectSchema(
                required: ["prompt", "provider", "model"],
                properties: [
                    "prompt": stringProp("Text prompt describing the video"),
                    "provider": stringProp("Provider ID"),
                    "model": stringProp("Model ID"),
                    "negative_prompt": stringProp("Negative prompt"),
                    "width": intProp("Video width in pixels"),
                    "height": intProp("Video height in pixels"),
                    "duration_seconds": numberProp("Video duration in seconds"),
                    "aspect_ratio": stringProp("Aspect ratio"),
                ]
            )
        ),
        MCPToolDefinition(
            name: "generate_poll",
            description: "Poll the status of an existing generation. Returns current status and progress.",
            inputSchema: objectSchema(
                required: ["generation_id"],
                properties: [
                    "generation_id": stringProp("The generation ID to poll"),
                    "wait": boolProp("If true, block until generation completes"),
                    "timeout": numberProp("Timeout in seconds when waiting"),
                ]
            )
        ),
        MCPToolDefinition(
            name: "list_generations",
            description: "List generations with optional filtering by status, provider, or search term.",
            inputSchema: objectSchema(
                required: [],
                properties: [
                    "status": stringProp("Filter by status (queued, submitted, processing, succeeded, failed, cancelled)"),
                    "provider": stringProp("Filter by provider ID"),
                    "limit": intProp("Max number of results (default 20)"),
                    "search": stringProp("Search term to filter by prompt text"),
                ]
            )
        ),
        MCPToolDefinition(
            name: "get_generation",
            description: "Get detailed information about a single generation.",
            inputSchema: objectSchema(
                required: ["generation_id"],
                properties: [
                    "generation_id": stringProp("The generation ID"),
                ]
            )
        ),
        MCPToolDefinition(
            name: "cancel_generation",
            description: "Cancel an active (queued/submitted/processing) generation.",
            inputSchema: objectSchema(
                required: ["generation_id"],
                properties: [
                    "generation_id": stringProp("The generation ID to cancel"),
                ]
            )
        ),
        MCPToolDefinition(
            name: "retry_generation",
            description: "Retry a failed generation with the same parameters.",
            inputSchema: objectSchema(
                required: ["generation_id"],
                properties: [
                    "generation_id": stringProp("The failed generation ID to retry"),
                ]
            )
        ),
        MCPToolDefinition(
            name: "list_providers",
            description: "List available video generation providers and their models, including capabilities and pricing.",
            inputSchema: objectSchema(required: [], properties: [:])
        ),
        MCPToolDefinition(
            name: "evaluate_quality",
            description: "Run quality evaluation on a completed generation's video output.",
            inputSchema: objectSchema(
                required: ["generation_id"],
                properties: [
                    "generation_id": stringProp("The generation ID to evaluate"),
                    "evaluator": stringProp("Evaluator type: heuristic (default) or llm-vision"),
                    "threshold": numberProp("Quality threshold (0-100)"),
                ]
            )
        ),
        MCPToolDefinition(
            name: "submit_feedback",
            description: "Submit quality feedback (0-100 score) for a generation.",
            inputSchema: objectSchema(
                required: ["generation_id", "score"],
                properties: [
                    "generation_id": stringProp("The generation ID"),
                    "score": numberProp("Quality score (0-100)"),
                    "reason": stringProp("Optional reason for the score"),
                ]
            )
        ),
        MCPToolDefinition(
            name: "get_metrics",
            description: "Get provider performance metrics (quality, latency, cost, success rate).",
            inputSchema: objectSchema(
                required: [],
                properties: [
                    "provider": stringProp("Filter by provider ID"),
                    "sort": stringProp("Sort by: quality, latency, cost, success_rate (default: quality)"),
                ]
            )
        ),
        MCPToolDefinition(
            name: "budget_status",
            description: "Get current budget status including daily spend, limits, and remaining budget.",
            inputSchema: objectSchema(required: [], properties: [:])
        ),
        MCPToolDefinition(
            name: "project_run",
            description: "Execute a multi-shot project DAG. Returns project status with all shot results.",
            inputSchema: objectSchema(
                required: ["project_id"],
                properties: [
                    "project_id": stringProp("The project ID to run"),
                    "strategy": stringProp("Routing strategy: cheapest, fastest, quality, manual, scatterGather"),
                    "evaluate": boolProp("Run quality evaluation on completed shots"),
                ]
            )
        ),
        MCPToolDefinition(
            name: "health_check",
            description: "Check health/availability of configured providers.",
            inputSchema: objectSchema(required: [], properties: [:])
        ),
    ]

    // MARK: - Resources

    static let allResources: [MCPResourceDefinition] = [
        MCPResourceDefinition(
            uri: "vortex://providers",
            name: "Available Providers",
            description: "List of configured video generation providers with their models and capabilities",
            mimeType: "application/json"
        ),
        MCPResourceDefinition(
            uri: "vortex://metrics",
            name: "Provider Metrics",
            description: "Current provider performance metrics (quality, latency, cost, success rate)",
            mimeType: "application/json"
        ),
        MCPResourceDefinition(
            uri: "vortex://budget",
            name: "Budget Status",
            description: "Current budget status including daily spend and limits",
            mimeType: "application/json"
        ),
    ]

    // MARK: - JSON Schema Helpers

    private static func objectSchema(required: [String], properties: [String: [String: AnyCodableValue]]) -> [String: AnyCodableValue] {
        var schema: [String: AnyCodableValue] = [
            "type": .string("object"),
            "properties": .dictionary(properties.mapValues { .dictionary($0) }),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        return schema
    }

    private static func stringProp(_ description: String) -> [String: AnyCodableValue] {
        ["type": .string("string"), "description": .string(description)]
    }

    private static func intProp(_ description: String) -> [String: AnyCodableValue] {
        ["type": .string("integer"), "description": .string(description)]
    }

    private static func numberProp(_ description: String) -> [String: AnyCodableValue] {
        ["type": .string("number"), "description": .string(description)]
    }

    private static func boolProp(_ description: String) -> [String: AnyCodableValue] {
        ["type": .string("boolean"), "description": .string(description)]
    }
}
