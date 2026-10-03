import Foundation

/// Uploads a reference image to fal's CDN so a fal endpoint can fetch it.
///
/// fal's docs describe this only through their SDKs. The REST shape below is
/// taken from fal's own JS client (`libs/client/src/storage.ts`, 2026-09):
///
/// 1. `POST https://rest.fal.ai/storage/upload/initiate?storage_type=fal-cdn-v3`
///    with `Authorization: Key <key>` and `{"content_type", "file_name"}`
///    → `{"upload_url", "file_url"}`
/// 2. `PUT <upload_url>` with the bytes and their `Content-Type`.
/// 3. Use `file_url` as the model input.
///
/// fal discourages data URIs for anything over "a few KB" (they inflate the
/// queue request), which is why fal alone uploads instead of inlining.
public enum FalUpload {

    public static let initiateURL = URL(string: "https://rest.fal.ai/storage/upload/initiate?storage_type=fal-cdn-v3")!

    public static func initiateRequest(for image: EncodedImage, apiKey: String,
                                       fileName: String? = nil) throws -> URLRequest {
        var req = URLRequest(url: initiateURL)
        req.httpMethod = "POST"
        req.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let name = fileName ?? "openflix-reference-\(UUID().uuidString.prefix(8)).\(image.fileExtension)"
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "content_type": image.mimeType,
            "file_name": name,
        ])
        return req
    }

    /// `(upload_url, file_url)` from the initiate response.
    public static func parseInitiate(_ data: Data) throws -> (upload: URL, file: URL) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let up = (json["upload_url"] as? String).flatMap(URL.init(string:)),
              let file = (json["file_url"] as? String).flatMap(URL.init(string:)) else {
            throw ProviderError.invalidResponse("fal upload: missing upload_url/file_url")
        }
        return (up, file)
    }

    public static func putRequest(for image: EncodedImage, to uploadURL: URL) -> URLRequest {
        var req = URLRequest(url: uploadURL)
        req.httpMethod = "PUT"
        req.setValue(image.mimeType, forHTTPHeaderField: "Content-Type")
        req.httpBody = image.data
        return req
    }

    /// Performs both steps. Returns the CDN URL to put in `image_url`.
    public static func upload(_ image: EncodedImage, apiKey: String,
                              session: URLSession = .shared) async throws -> URL {
        let (initData, initResp) = try await session.data(for: try initiateRequest(for: image, apiKey: apiKey))
        try check(initResp, initData, step: "initiate")
        let (uploadURL, fileURL) = try parseInitiate(initData)
        let (putData, putResp) = try await session.data(for: putRequest(for: image, to: uploadURL))
        try check(putResp, putData, step: "upload")
        return fileURL
    }

    private static func check(_ response: URLResponse, _ data: Data, step: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse("fal upload \(step): no HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ProviderError.httpError(http.statusCode, "fal upload \(step): \(body.prefix(300))")
        }
    }
}
