import Foundation

// MARK: - Global output helpers

enum Output {
    static var pretty = false

    /// Write a JSON-encodable value to stdout.
    static func emit<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let str = String(data: data, encoding: .utf8) else {
            fputs("{\"error\":\"JSON encoding failed\",\"code\":\"internal_error\"}\n", stderr)
            return
        }
        print(str)
    }

    /// Write a raw dictionary to stdout as JSON.
    static func emitDict(_ dict: [String: Any]) {
        let opts: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: opts),
              let str = String(data: data, encoding: .utf8) else {
            fputs("{\"error\":\"JSON serialization failed\",\"code\":\"internal_error\"}\n", stderr)
            return
        }
        print(str)
    }

    /// Write an array of dictionaries to stdout as JSON.
    static func emitArray(_ array: [[String: Any]]) {
        let opts: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? JSONSerialization.data(withJSONObject: array, options: opts),
              let str = String(data: data, encoding: .utf8) else {
            fputs("{\"error\":\"JSON serialization failed\",\"code\":\"internal_error\"}\n", stderr)
            return
        }
        print(str)
    }

    /// Write a streaming event (newline-delimited JSON) to stdout.
    static func emitEvent(_ event: [String: Any]) {
        let opts: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? JSONSerialization.data(withJSONObject: event, options: opts),
              let str = String(data: data, encoding: .utf8) else {
            fputs("{\"error\":\"Event serialization failed\",\"code\":\"internal_error\"}\n", stderr)
            return
        }
        print(str)
        // Flush stdout immediately for streaming
        fflush(stdout)
    }

    /// Write an error to stderr as JSON and exit.
    static func fail(_ error: OpenFlixError, exitCode: Int32 = 1) -> Never {
        writeError(error.errorDescription ?? error.code, code: error.code)
        exit(exitCode)
    }

    /// Write a plain error to stderr as JSON and exit.
    static func failMessage(_ message: String, code: String = "error", exitCode: Int32 = 1) -> Never {
        writeError(message, code: code)
        exit(exitCode)
    }

    /// Write a structured error to stderr as JSON and exit (for MCP/agent consumers).
    static func failStructured(_ error: OpenFlixError, exitCode: Int32 = 1) -> Never {
        let structured = StructuredError.from(error)
        let dict: [String: Any] = ["error": structured.jsonRepresentation]
        let opts: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: opts),
           let str = String(data: data, encoding: .utf8) {
            fputs(str + "\n", stderr)
        }
        exit(exitCode)
    }

    /// Write a structured error dict to stderr (non-exiting, for MCP responses).
    static func writeStructuredError(_ error: OpenFlixError) -> [String: Any] {
        return StructuredError.from(error).jsonRepresentation
    }

    private static func writeError(_ message: String, code: String) {
        let dict: [String: Any] = ["error": message, "code": code]
        let opts: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted] : []
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: opts),
              let str = String(data: data, encoding: .utf8) else { return }
        fputs(str + "\n", stderr)
    }
}
