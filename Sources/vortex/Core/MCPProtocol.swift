import Foundation

// MARK: - MCP JSON-RPC 2.0 Protocol Types

struct MCPRequest: Codable {
    let jsonrpc: String
    let id: AnyCodableValue?
    let method: String
    let params: [String: AnyCodableValue]?
}

struct MCPResponse: Codable {
    let jsonrpc: String
    let id: AnyCodableValue?
    let result: AnyCodableValue?
    let error: MCPError?

    static func success(id: AnyCodableValue?, result: AnyCodableValue) -> MCPResponse {
        MCPResponse(jsonrpc: "2.0", id: id, result: result, error: nil)
    }

    static func error(id: AnyCodableValue?, code: Int, message: String, data: AnyCodableValue? = nil) -> MCPResponse {
        MCPResponse(jsonrpc: "2.0", id: id, result: nil, error: MCPError(code: code, message: message, data: data))
    }
}

struct MCPError: Codable {
    let code: Int
    let message: String
    let data: AnyCodableValue?
}

struct MCPNotification: Codable {
    let jsonrpc: String
    let method: String
    let params: [String: AnyCodableValue]?
}

// MARK: - MCP Tool / Resource Definitions

struct MCPToolDefinition: Codable {
    let name: String
    let description: String
    let inputSchema: [String: AnyCodableValue]

    func toAnyCodable() -> AnyCodableValue {
        .dictionary([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": .dictionary(inputSchema),
        ])
    }
}

struct MCPResourceDefinition: Codable {
    let uri: String
    let name: String
    let description: String
    let mimeType: String

    func toAnyCodable() -> AnyCodableValue {
        .dictionary([
            "uri": .string(uri),
            "name": .string(name),
            "description": .string(description),
            "mimeType": .string(mimeType),
        ])
    }
}

// MARK: - MCP Standard Error Codes

enum MCPErrorCode {
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
}
