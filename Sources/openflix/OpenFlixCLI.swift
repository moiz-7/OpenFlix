import ArgumentParser
import Foundation

@main
struct OpenFlix: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "openflix",
        abstract: "AI video generation CLI — agent-friendly, JSON-first",
        discussion: """
        OpenFlix submits and tracks AI video generation jobs across multiple providers.
        All output is JSON (stdout). Errors go to stderr with exit code 1.

        QUICK START
          # Store your API key
          openflix keys set fal your-fal-key

          # Generate a video and wait for it
          openflix generate "a cat on the moon" --provider fal \\
              --model fal-ai/minimax/hailuo-02 --wait

          # Stream progress events
          openflix generate "neon city timelapse" --provider fal \\
              --model fal-ai/veo3 --stream

          # Check on a running generation
          openflix status <generation-id> --wait

          # List recent generations
          openflix list --status succeeded --limit 10

          # Cost summary
          openflix cost

        ENVIRONMENT VARIABLES
          OPENFLIX_FAL_KEY       API key for fal.ai
          OPENFLIX_REPLICATE_KEY API key for Replicate
          OPENFLIX_RUNWAY_KEY    API key for Runway
          OPENFLIX_LUMA_KEY      API key for Luma
          OPENFLIX_KLING_KEY     API key for Kling
          OPENFLIX_MINIMAX_KEY   API key for MiniMax
          OPENFLIX_API_KEY       Generic fallback key (all providers)

          Legacy VORTEX_*_KEY variables are still supported as fallback.

        MULTI-SHOT PROJECTS
          openflix project create --file spec.json
          openflix project run <project-id> --stream
          openflix project status <project-id> --detail
          openflix project export <project-id> --manifest

        BATCH GENERATION
          openflix batch --file shots.json --wait --concurrency 4

        DATA STORAGE
          ~/.openflix/store.json       Generation history
          ~/.openflix/downloads/       Downloaded videos
          ~/.openflix/projects/        Project data
        """,
        version: "1.0.0",
        subcommands: [
            Generate.self,
            Status.self,
            List.self,
            Download.self,
            Cancel.self,
            Delete.self,
            Retry.self,
            Purge.self,
            Health.self,
            Providers.self,
            Models.self,
            Keys.self,
            Cost.self,
            Batch.self,
            ProjectGroup.self,
            Daemon.self,
            Evaluate.self,
            Feedback.self,
            Metrics.self,
            Budget.self,
            MCP.self,
        ]
    )
}
