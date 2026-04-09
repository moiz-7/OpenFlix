import ArgumentParser
import Foundation

struct Batch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "batch",
        abstract: "Submit multiple generations in parallel",
        discussion: """
        Reads a JSON array of generation specs from a file or stdin and submits
        them in parallel with configurable concurrency.

        EXAMPLES
          vortex batch --file shots.json --wait --concurrency 4
          cat shots.json | vortex batch --wait
          vortex batch --file shots.json --stream --skip-download

        INPUT FORMAT
          [
            {"prompt": "cat on moon", "provider": "fal", "model": "fal-ai/veo3", "tag": "shot1"},
            {"prompt": "neon city", "provider": "runway", "model": "gen4_turbo", "tag": "shot2"}
          ]
        """
    )

    @Option(name: .long, help: "JSON file with array of generation specs")
    var file: String?

    @Option(name: .long, help: "Max parallel generations (default: 4)")
    var concurrency: Int = 4

    @Flag(name: .long, help: "Block until all generations complete")
    var wait: Bool = false

    @Flag(name: .long, help: "Stream newline-delimited JSON progress events")
    var stream: Bool = false

    @Flag(name: .long, help: "Skip downloading videos after generation")
    var skipDownload: Bool = false

    @Option(name: .long, help: "Max seconds to wait per generation (default: 600)")
    var timeout: Double = 600

    @Option(name: .long, help: "Max retries per generation on failure (default: 1)")
    var retry: Int = 1

    @Option(name: .long, help: "API key (overrides env var and keychain)")
    var apiKey: String?

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        Output.pretty = pretty

        guard concurrency > 0 else {
            Output.failMessage("--concurrency must be positive", code: "invalid_input")
        }
        guard retry >= 0 else {
            Output.failMessage("--retry must be non-negative", code: "invalid_input")
        }

        // Read input
        let data: Data
        if let filePath = file {
            let url = URL(fileURLWithPath: filePath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                Output.failMessage("File not found: \(filePath)", code: "file_not_found")
            }
            do { data = try Data(contentsOf: url) }
            catch { Output.failMessage("Cannot read file: \(error.localizedDescription)", code: "file_error") }
        } else {
            // Read from stdin
            var stdinData = Data()
            while let line = readLine(strippingNewline: false) {
                stdinData.append(Data(line.utf8))
            }
            guard !stdinData.isEmpty else {
                Output.failMessage("No input provided. Use --file or pipe JSON to stdin.", code: "no_input")
            }
            data = stdinData
        }

        // Parse batch items
        let decoder = JSONDecoder()
        let items: [BatchItem]
        do {
            items = try decoder.decode([BatchItem].self, from: data)
        } catch {
            Output.failMessage("Invalid batch JSON: \(error.localizedDescription)", code: "invalid_json")
        }

        guard !items.isEmpty else {
            Output.failMessage("Batch array is empty", code: "invalid_input")
        }

        // Validate all items
        for (i, item) in items.enumerated() {
            guard !item.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                Output.failMessage("Item \(i): prompt is empty", code: "invalid_input")
            }
            do {
                _ = try ProviderRegistry.shared.provider(for: item.provider)
            } catch {
                Output.failMessage("Item \(i): \(error.localizedDescription)", code: "invalid_input")
            }
        }

        // Execute batch with concurrency limit
        let results = await executeBatch(items: items)

        // Emit results
        Output.emitArray(results)
    }

    private func executeBatch(items: [BatchItem]) async -> [[String: Any]] {
        let semaphore = AsyncSemaphore(limit: concurrency)
        let resultsActor = ResultsCollector()

        await withTaskGroup(of: Void.self) { group in
            for (index, item) in items.enumerated() {
                group.addTask {
                    await semaphore.wait()
                    defer { Task { await semaphore.signal() } }

                    let result = await self.executeItem(item, index: index)
                    await resultsActor.add(index: index, result: result)
                }
            }
        }

        return await resultsActor.sorted()
    }

    private func executeItem(_ item: BatchItem, index: Int) async -> [String: Any] {
        let options = GenerationEngine.Options(
            pollInterval: 3,
            timeout: timeout,
            outputURL: nil,
            stream: stream,
            skipDownload: skipDownload,
            maxRetries: retry
        )

        let imageURL = item.image.flatMap { URL(string: $0) }
        var extraParams: [String: Any] = [:]
        if let ep = item.extraParams {
            for (k, v) in ep { extraParams[k] = v }
        }

        do {
            let gen: CLIGeneration
            if wait || stream {
                gen = try await GenerationEngine.submitAndWait(
                    prompt: item.prompt,
                    negativePrompt: item.negativePrompt,
                    provider: item.provider,
                    model: item.model,
                    durationSeconds: item.duration,
                    aspectRatio: item.aspectRatio,
                    width: item.width,
                    height: item.height,
                    referenceImageURL: imageURL,
                    extraParams: extraParams,
                    apiKey: apiKey,
                    options: options
                )
            } else {
                gen = try await GenerationEngine.submit(
                    prompt: item.prompt,
                    negativePrompt: item.negativePrompt,
                    provider: item.provider,
                    model: item.model,
                    durationSeconds: item.duration,
                    aspectRatio: item.aspectRatio,
                    width: item.width,
                    height: item.height,
                    referenceImageURL: imageURL,
                    extraParams: extraParams,
                    apiKey: apiKey
                )
            }

            var result = gen.jsonRepresentation
            if let tag = item.tag { result["tag"] = tag }
            result["batch_index"] = index
            return result
        } catch {
            var result: [String: Any] = [
                "status": "failed",
                "batch_index": index,
                "error_message": (error as? VortexError)?.errorDescription ?? error.localizedDescription,
            ]
            if let tag = item.tag { result["tag"] = tag }
            return result
        }
    }
}

// MARK: - Concurrency helpers

private actor AsyncSemaphore {
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.count = limit
    }

    func wait() async {
        if count > 0 {
            count -= 1
        } else {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    func signal() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            count += 1
        }
    }
}

private actor ResultsCollector {
    private var results: [(index: Int, result: [String: Any])] = []

    func add(index: Int, result: [String: Any]) {
        results.append((index, result))
    }

    func sorted() -> [[String: Any]] {
        results.sorted { $0.index < $1.index }.map { $0.result }
    }
}
