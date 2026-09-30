import Foundation
import OpenFlixKit

/// The HTTP/1.1 subset the bridge speaks: one request per connection,
/// `Content-Length` bodies only, JSON in and out. Deliberately small — every
/// feature a general server has (chunked bodies, keep-alive, pipelining) is
/// surface this one does not need to defend.
struct BridgeHTTPRequest: Equatable {
    let method: String
    /// Path without the query string.
    let path: String
    /// Header names lowercased.
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

struct BridgeHTTPResponse: Equatable {
    let status: Int
    var headers: [String: String] = [:]
    let body: Data

    static func json(_ status: Int, _ value: JSONValue, headers: [String: String] = [:]) -> BridgeHTTPResponse {
        BridgeHTTPResponse(status: status, headers: headers, body: Data((value.jsonString() + "\n").utf8))
    }

    func serialized() -> Data {
        var lines = ["HTTP/1.1 \(status) \(Self.reason(status))"]
        var all = headers
        all["Content-Type"] = all["Content-Type"] ?? "application/json"
        all["Content-Length"] = String(body.count)
        all["Connection"] = "close"
        all["Cache-Control"] = "no-store"
        for key in all.keys.sorted() { lines.append("\(key): \(all[key]!)") }
        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        data.append(body)
        return data
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 411: return "Length Required"
        case 413: return "Content Too Large"
        case 428: return "Precondition Required"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}

enum BridgeHTTPParser {

    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 256 * 1024

    enum Result: Equatable {
        /// Keep reading.
        case incomplete
        case complete(BridgeHTTPRequest)
        /// Answer with this status and close.
        case invalid(status: Int, message: String)
    }

    static func parse(_ data: Data) -> Result {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: separator) else {
            return data.count > maxHeaderBytes
                ? .invalid(status: 431, message: "request headers too large")
                : .incomplete
        }
        guard end.lowerBound <= maxHeaderBytes else {
            return .invalid(status: 431, message: "request headers too large")
        }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .invalid(status: 400, message: "request headers are not UTF-8")
        }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
            return .invalid(status: 400, message: "malformed request line")
        }
        let method = String(requestLine[0])
        let target = String(requestLine[1])
        guard target.hasPrefix("/") else {
            return .invalid(status: 400, message: "request target must be a path")
        }
        let path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                return .invalid(status: 400, message: "malformed header line")
            }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" ") else {
                return .invalid(status: 400, message: "malformed header name")
            }
            // A repeated framing header is how request smuggling starts.
            if headers[name] != nil, name == "content-length" || name == "transfer-encoding" || name == "authorization" {
                return .invalid(status: 400, message: "duplicate \(name) header")
            }
            headers[name] = value
        }

        if headers["transfer-encoding"] != nil {
            return .invalid(status: 501, message: "Transfer-Encoding is not supported; send Content-Length")
        }

        var length = 0
        if let raw = headers["content-length"] {
            guard let value = Int(raw), value >= 0 else {
                return .invalid(status: 400, message: "invalid Content-Length")
            }
            length = value
        } else if method == "POST" {
            return .invalid(status: 411, message: "POST needs a Content-Length")
        }
        guard length <= maxBodyBytes else {
            return .invalid(status: 413, message: "body larger than \(maxBodyBytes) bytes")
        }

        let bodyStart = end.upperBound
        let available = data.count - (bodyStart - data.startIndex)
        guard available >= length else { return .incomplete }
        let body = data[bodyStart..<(bodyStart + length)]
        return .complete(BridgeHTTPRequest(method: method, path: path, headers: headers, body: Data(body)))
    }
}
