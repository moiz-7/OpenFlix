import ArgumentParser
import Foundation

struct Quickstart: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quickstart",
        abstract: "Guided onboarding: the generate -> compare -> vote -> publish loop",
        discussion: """
        Checks which provider keys are configured (locally, no network) and
        prints the canonical OpenFlix workflow as copy-pasteable commands.

        Like --help, this command prints plain text. Pass --json to get the
        same content wrapped in a JSON object with a "text" field.
        """
    )

    @Flag(name: .long, help: "Wrap the output in JSON with a \"text\" field")
    var json: Bool = false

    @Flag(name: .long, help: "Pretty-print JSON output (with --json)")
    var pretty: Bool = false

    func run() throws {
        // 1. Key check — local only (flag/env/keychain), never hits the network.
        let allProviders = ProviderRegistry.shared.all.map { $0.providerId }
        let configured = ProviderRouter.availableProviders()

        var lines: [String] = []
        lines.append("OpenFlix Quickstart")
        lines.append("===================")
        lines.append("")
        lines.append("Provider keys (checked locally):")
        for p in allProviders.sorted() {
            if configured.contains(p) {
                lines.append("  [ok] \(p)")
            } else {
                lines.append("  [--] \(p)   (set with: openflix keys set \(p) <key>)")
            }
        }
        if configured.isEmpty {
            lines.append("")
            lines.append("  No keys configured yet — start with one provider:")
            lines.append("    openflix keys set fal <your-fal-key>")
        }
        lines.append("")

        // 2. THE LOOP — concrete, copy-pasteable, built around a real recipe
        //    from ./recipes when the repo checkout is present.
        let recipePath = exampleRecipePath()
        let recipeRef = recipePath ?? "<recipe-id>"

        lines.append("THE LOOP — how OpenFlix gets smarter with every video:")
        lines.append("  generate -> compare -> vote -> publish")
        lines.append("")
        lines.append("1. Generate a take from a recipe (repeatable, shareable settings):")
        if recipePath == nil {
            lines.append("     openflix recipe init \"golden hour city skyline, slow dolly\" --name my-first-recipe")
        }
        lines.append("     openflix recipe run \(recipeRef) --wait")
        lines.append("")
        lines.append("2. Generate a challenger — let smart routing pick the model:")
        lines.append("     openflix generate \"golden hour city skyline, slow dolly\" --route smart --category cinematic --wait")
        lines.append("")
        lines.append("3. Compare the two takes head to head:")
        lines.append("     openflix compare <gen-id-1> <gen-id-2>")
        lines.append("")
        lines.append("4. Vote — your feedback feeds smarter routing for everyone:")
        lines.append("     openflix feedback <winning-gen-id> --score 90")
        lines.append("")
        lines.append("5. Publish your recipe so others can run and fork it:")
        lines.append("     openflix recipe publish <recipe-id>")
        lines.append("")
        lines.append("Before you spend money:")
        lines.append("  * Add --dry-run to any generate / recipe run to validate without submitting.")
        lines.append("  * Cap spending: openflix budget set --daily-limit 5.00 --per-generation-max 0.50")
        lines.append("")
        lines.append("Explore:")
        lines.append("  openflix recipe list              # your saved recipes")
        lines.append("  openflix recipe search \"anime\"    # community recipes in the registry")
        lines.append("  openflix models --provider fal    # models per provider")

        let text = lines.joined(separator: "\n")

        if json {
            Output.pretty = pretty
            Output.emitDict([
                "text": text,
                "providers_configured": configured.sorted(),
                "providers_available": allProviders.sorted(),
            ])
        } else {
            print(text)
        }
    }

    /// First .openflix recipe under ./recipes, if running from a repo checkout.
    private func exampleRecipePath() -> String? {
        let dir = "recipes"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        guard let file = entries.filter({ $0.hasSuffix(".openflix") }).sorted().first else { return nil }
        return "\(dir)/\(file)"
    }
}
