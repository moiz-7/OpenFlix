import Foundation

/// HTTP client for the OpenFlix recipe registry.
/// Base URL is configurable via the OPENFLIX_REGISTRY_URL environment variable.
enum RegistryClient {
    static var baseURL: String {
        ProcessInfo.processInfo.environment["OPENFLIX_REGISTRY_URL"]
            ?? "https://registry.openflix.app"
    }

    /// Publish a recipe bundle to the registry.
    static func publish(bundle: RecipeBundle, author: String? = nil) async throws -> (id: String, url: String) {
        var bundleToPublish = bundle
        if let author { bundleToPublish.author = author }
        let data = try bundleToPublish.encode()

        guard let endpoint = URL(string: "\(baseURL)/api/recipes") else {
            throw OpenFlixError.invalidResponse("Invalid registry URL: \(baseURL)/api/recipes")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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

    /// Publish benchmark results to the registry.
    static func publishBenchmark(results: [String: Any], author: String? = nil) async throws -> (id: String, url: String) {
        var body = results
        if let author { body["author"] = author }
        let data = try JSONSerialization.data(withJSONObject: body)

        guard let endpoint = URL(string: "\(baseURL)/api/benchmarks") else {
            throw OpenFlixError.invalidResponse("Invalid registry URL: \(baseURL)/api/benchmarks")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
