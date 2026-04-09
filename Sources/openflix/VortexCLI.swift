import ArgumentParser
import Foundation

@main
struct Vortex: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vortex",
        abstract: "AI video generation CLI — agent-friendly, JSON-first",
        discussion: """
        Vortex submits and tracks AI video generation jobs across multiple providers.
        All output is JSON (stdout). Errors go to stderr with exit code 1.

        QUICK START
          # Store your API key
          vortex keys set fal your-fal-key

          # Generate a video and wait for it
          vortex generate "a cat on the moon" --provider fal \\
              --model fal-ai/minimax/hailuo-02 --wait

          # Stream progress events
          vortex generate "neon city timelapse" --provider fal \\
              --model fal-ai/veo3 --stream

          # Check on a running generation
          vortex status <generation-id> --wait

          # List recent generations
          vortex list --status succeeded --limit 10

          # Cost summary
          vortex cost

        ENVIRONMENT VARIABLES
          VORTEX_FAL_KEY         API key for fal.ai
          VORTEX_REPLICATE_KEY   API key for Replicate
          VORTEX_RUNWAY_KEY      API key for Runway
          VORTEX_LUMA_KEY        API key for Luma
          VORTEX_KLING_KEY       API key for Kling
          VORTEX_MINIMAX_KEY     API key for MiniMax
          VORTEX_API_KEY         Generic fallback key (all providers)

        MULTI-SHOT PROJECTS
          vortex project create --file spec.json
          vortex project run <project-id> --stream
          vortex project status <project-id> --detail
          vortex project export <project-id> --manifest

        BATCH GENERATION
          vortex batch --file shots.json --wait --concurrency 4

        DATA STORAGE
          ~/.vortex/store.json       Generation history
          ~/.vortex/downloads/       Downloaded videos
          ~/.vortex/projects/        Project data
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
