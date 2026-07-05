import Foundation
import OpenFlixKit

/// HTTP client for the OpenFlix recipe registry.
/// Base URL is configurable via the OPENFLIX_REGISTRY_URL environment variable.
enum RegistryClient {
    static var baseURL: String {
        ProcessInfo.processInfo.environment["OPENFLIX_REGISTRY_URL"]
            ?? "https://registry.openflix.app"
    }

    /// Resolve a registry auth token: explicit flag value first, then the
    /// OPENFLIX_REGISTRY_TOKEN env var. Returns nil when unauthenticated
    /// (the registry may run open in dev).
    static func resolveToken(flagValue: String?) -> String? {
        if let v = flagValue, !v.isEmpty { return v }
        if let v = ProcessInfo.processInfo.environment["OPENFLIX_REGISTRY_TOKEN"], !v.isEmpty { return v }
        return nil
    }

    /// Publish a recipe bundle to the registry.
    static func publish(bundle: RecipeBundle, author: String? = nil, token: String? = nil) async throws -> (id: String, url: String) {
        var bundleToPublish = bundle
        if let author { bundleToPublish.author = author }
        let data = try bundleToPublish.encode()

        guard let endpoint = URL(string: "\(baseURL)/api/recipes") else {
            throw OpenFlixError.invalidResponse("Invalid registry URL: \(baseURL)/api/recipes")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = data

        let session = makeSession()
        let (responseData, _) = try await session.jsonData(for: request)
        let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] ?? [:]
        guard let id = json["id"] as? String, let url = json["url"] as? String else {
            throw OpenFlixError.invalidResponse("Registry returned invalid response")
        }
        return (id: id, url: url)
    }

    /// Fetch a recipe bundle from the registry by ID.
    static func fetch(recipeId: String) async throws -> RecipeBundle {
        guard let url = URL(string: "\(baseURL)/api/recipes/\(recipeId)/bundle") else {
            throw OpenFlixError.invalidResponse("Invalid registry URL for recipe: \(recipeId)")
        }
        let session = makeSession()
        let (data, _) = try await session.jsonData(for: URLRequest(url: url))
        return try RecipeBundle.decode(from: data)
    }

    /// Fetch a recipe bundle from a full URL.
    static func fetchFromURL(_ urlString: String) async throws -> RecipeBundle {
        guard let url = URL(string: urlString) else {
            throw OpenFlixError.invalidResponse("Invalid URL: \(urlString)")
        }
        let session = makeSession()
        let (data, _) = try await session.jsonData(for: URLRequest(url: url))
        return try RecipeBundle.decode(from: data)
    }

    /// Search recipes in the registry.
    static func search(query: String? = nil, category: String? = nil, limit: Int = 20) async throws -> [[String: Any]] {
        guard var components = URLComponents(string: "\(baseURL)/api/recipes") else {
            throw OpenFlixError.invalidResponse("Invalid registry URL: \(baseURL)/api/recipes")
        }
        var items: [URLQueryItem] = []
        if let q = query, !q.isEmpty { items.append(URLQueryItem(name: "q", value: q)) }
        if let c = category, !c.isEmpty { items.append(URLQueryItem(name: "category", value: c)) }
        items.append(URLQueryItem(name: "limit", value: "\(limit)"))
        components.queryItems = items

        guard let searchURL = components.url else {
            throw OpenFlixError.invalidResponse("Failed to construct registry search URL")
        }
        let session = makeSession()
        let (data, _) = try await session.jsonData(for: URLRequest(url: searchURL))
        let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return array
    }

    /// Fetch the aggregate preference summary used by smart routing.
    /// Returns raw data so callers can cache the exact payload.
    static func fetchPreferenceSummaryData(category: String? = nil) async throws -> Data {
        guard var components = URLComponents(string: "\(baseURL)/api/preferences/summary") else {
            throw OpenFlixError.invalidResponse("Invalid registry URL: \(baseURL)/api/preferences/summary")
        }
        if let category, !category.isEmpty {
            components.queryItems = [URLQueryItem(name: "category", value: category)]
        }
        guard let url = components.url else {
            throw OpenFlixError.invalidResponse("Failed to construct preference summary URL")
        }
        let session = makeSession()
        let (data, _) = try await session.jsonData(for: URLRequest(url: url))
        return data
    }

    /// Publish a workflow spec to the registry.
    /// Contract: POST /api/workflows {"name", "description"?, "spec": {...}}
    /// → {"id", "url"} ("url" is additive; nil when the server omits it).
    static func publishWorkflow(name: String, description: String?,
                                spec: [String: Any], token: String?) async throws -> (id: String, url: String?) {
        var body: [String: Any] = ["name": name, "spec": spec]
        if let description, !description.isEmpty { body["description"] = description }
        let data = try JSONSerialization.data(withJSONObject: body)

        guard let endpoint = URL(string: "\(baseURL)/api/workflows") else {
            throw OpenFlixError.invalidResponse("Invalid registry URL: \(baseURL)/api/workflows")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = data

        let session = makeSession()
        let (responseData, _) = try await session.jsonData(for: request)
        let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] ?? [:]
        guard let id = json["id"] as? String else {
            throw OpenFlixError.invalidResponse("Registry returned invalid response")
        }
        return (id: id, url: json["url"] as? String)
    }

    /// Credit a workflow download counter — fire-and-forget: short timeout,
    /// all errors swallowed, never blocks or fails an import meaningfully.
    static func creditWorkflowDownload(id: String, base: String? = nil) async {
        let root = base ?? baseURL
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(root)/api/workflows/\(encoded)/download") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        _ = try? await URLSession(configuration: config).jsonData(for: request)
    }

    /// Fetch a workflow from the registry by id.
    /// Contract: GET /api/workflows/{id} → {"id","name","description","spec": {...}, ...}.
    /// `base` overrides the default registry root (full-URL imports).
    static func fetchWorkflow(id: String, base: String? = nil) async throws -> [String: Any] {
        let root = base ?? baseURL
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(root)/api/workflows/\(encoded)") else {
            throw OpenFlixError.invalidResponse("Invalid registry URL for workflow: \(id)")
        }
        let session = makeSession()
        let (data, _) = try await session.jsonData(for: URLRequest(url: url))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenFlixError.invalidResponse("Registry returned invalid workflow response")
        }
        return json
    }

    /// Publish benchmark results to the registry.
    static func publishBenchmark(results: [String: Any], author: String? = nil, token: String? = nil) async throws -> (id: String, url: String) {
        var body = results
        if let author { body["author"] = author }
        let data = try JSONSerialization.data(withJSONObject: body)

        guard let endpoint = URL(string: "\(baseURL)/api/benchmarks") else {
            throw OpenFlixError.invalidResponse("Invalid registry URL: \(baseURL)/api/benchmarks")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = data

        let session = makeSession()
        let (responseData, _) = try await session.jsonData(for: request)
        let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] ?? [:]
        guard let id = json["id"] as? String, let url = json["url"] as? String else {
            throw OpenFlixError.invalidResponse("Registry returned invalid response")
        }
        return (id: id, url: url)
    }
}
