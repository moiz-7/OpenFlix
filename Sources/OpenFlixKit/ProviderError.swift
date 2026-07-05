import Foundation

/// Provider/network errors thrown by kit provider clients.
///
/// This is the provider/network slice of the CLI's `OpenFlixError` (which
/// keeps its full case surface and stable JSON `code` strings — the CLI maps
/// `ProviderError` into it at the call boundary). `code` values here are
/// identical to the CLI's so the machine-readable stderr contract never
/// changes regardless of which side threw.
public enum ProviderError: Error, LocalizedError {
    case httpError(Int, String)
    case invalidResponse(String)
    case rateLimited(String, retryAfter: Int?)
    case cancelNotSupported(String)

    public var errorDescription: String? {
        switch self {
        case .httpError(let c, let m):    return "HTTP \(c): \(m)"
        case .invalidResponse(let m):     return "Invalid response: \(m)"
        case .rateLimited(let p, let retryAfter):
            if let s = retryAfter { return "\(p) rate limit exceeded — retry in \(s)s" }
            return "\(p) rate limit exceeded — retry later"
        case .cancelNotSupported(let p):  return "cancel not supported by \(p)"
        }
    }

    public var code: String {
        switch self {
        case .httpError:          return "http_error"
        case .invalidResponse:    return "invalid_response"
        case .rateLimited:        return "rate_limited"
        case .cancelNotSupported: return "cancel_not_supported"
        }
    }
}
