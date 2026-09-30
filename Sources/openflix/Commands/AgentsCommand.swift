import ArgumentParser
import Foundation
import OpenFlixKit

/// `openflix agents` — who may use the HTTP bridge, and for what.
struct AgentsGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agents",
        abstract: "Grant, list and revoke agent access to the HTTP bridge",
        discussion: """
        A grant gives one agent a bearer token for `openflix serve`, limited to
        the kinds of action you name (by effect) and, for spending, a daily cap
        in US dollars. Only a hash of the token is stored; the token is printed
        once, when granted.

        EFFECTS
          read         look things up (library, generations, budget, providers)
          refresh      poll a generation already paid for
          control      drive the app's player
          local_write  write local state (quality scores)
          destructive  cancel generations
          spend        start paid generations (needs --daily-cap)
          share        send a vote to the community registry

        EXAMPLES
          openflix agents grant harbor --effects read,refresh,control
          openflix agents grant harbor --effects read,refresh,control,spend --daily-cap 5
          openflix agents list
          openflix agents revoke harbor
        """,
        subcommands: [AgentsGrant.self, AgentsList.self, AgentsRevoke.self]
    )
}

struct AgentsGrant: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "grant",
        abstract: "Create or replace an agent's grant and print its token (once)"
    )

    @Argument(help: "Agent name (letters, digits, '.', '_', '-'), e.g. harbor")
    var name: String

    @Option(name: .long, help: "Comma-separated effects the agent may use (default: read,refresh)")
    var effects: String = "read,refresh"

    @Option(name: .customLong("daily-cap"), help: "Most the agent may spend per day, in USD (default 0: no spending)")
    var dailyCap: Double = 0

    @Option(name: .customLong("expires-days"), help: "Expire the grant after this many days")
    var expiresDays: Int?

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty
        var parsed: [ActionEffect] = []
        for raw in effects.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !raw.isEmpty {
            guard let effect = ActionEffect(rawValue: raw) else {
                Output.failMessage("Unknown effect '\(raw)'. Known: \(ActionEffect.allCases.map(\.rawValue).joined(separator: ", "))",
                                   code: "invalid_input")
            }
            parsed.append(effect)
        }
        guard !parsed.isEmpty else { Output.failMessage("--effects is empty", code: "invalid_input") }
        if let expiresDays, !(1...3650).contains(expiresDays) {
            Output.failMessage("--expires-days must be 1-3650", code: "invalid_input")
        }
        let expiresAt = expiresDays.map { Date().addingTimeInterval(Double($0) * 86_400) }

        do {
            let (grant, token) = try AgentGrantStore.shared.grant(name: name, effects: parsed,
                                                                  dailyCapUSD: dailyCap, expiresAt: expiresAt)
            var out = grant.summary(spentToday: AgentGrantStore.shared.spentToday(grant.name))
            out["token"] = token
            out["note"] = "This token is shown once. Store it in the agent's secret store (e.g. macOS Keychain), never in a file or a prompt. Replacing or revoking the grant invalidates it."
            Output.emitDict(out)
        } catch let error as OpenFlixError {
            Output.fail(error)
        }
    }
}

struct AgentsList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List agent grants (never the tokens)"
    )

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty
        let store = AgentGrantStore.shared
        let now = Date()
        Output.emitArray(store.all().map { grant in
            var d = grant.summary(spentToday: store.spentToday(grant.name, now: now))
            d["expired"] = grant.isExpired(at: now)
            return d
        })
    }
}

struct AgentsRevoke: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "revoke",
        abstract: "Revoke an agent's grant; its token stops working immediately"
    )

    @Argument(help: "Agent name")
    var name: String

    mutating func run() async throws {
        do {
            let removed = try AgentGrantStore.shared.revoke(name: name)
            guard removed else { Output.failMessage("No grant named '\(name)'", code: "not_found") }
            Output.emitDict(["revoked": name])
        } catch let error as OpenFlixError {
            Output.fail(error)
        }
    }
}
