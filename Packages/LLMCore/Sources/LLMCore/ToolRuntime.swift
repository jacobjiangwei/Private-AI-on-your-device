import Foundation

public protocol LLMTool: Sendable {
    var definition: ToolDefinition { get }
    func isConcurrencySafe(arguments: [String: JSONValue]) -> Bool
    func execute(arguments: [String: JSONValue]) async throws -> String
}

public extension LLMTool {
    func isConcurrencySafe(arguments: [String: JSONValue]) -> Bool {
        false
    }
}

public enum ToolRuntimeError: Error, Equatable, LocalizedError, Sendable {
    case duplicateTool(String)
    case unknownTool(String)

    public var errorDescription: String? {
        switch self {
        case .duplicateTool(let name):
            "A tool named '\(name)' is already registered."
        case .unknownTool(let name):
            "The model requested an unknown tool named '\(name)'."
        }
    }
}

public struct ToolExecution: Equatable, Sendable {
    public let name: String
    public let arguments: [String: JSONValue]
    public let content: String
    public let succeeded: Bool

    public init(
        name: String,
        arguments: [String: JSONValue],
        content: String,
        succeeded: Bool
    ) {
        self.name = name
        self.arguments = arguments
        self.content = content
        self.succeeded = succeeded
    }
}

public actor ToolRuntime {
    private let tools: [String: any LLMTool]
    private let outputLimitBytes: Int

    public init(tools: [any LLMTool], outputLimitBytes: Int = 16 * 1_024) throws {
        var registeredTools: [String: any LLMTool] = [:]
        for tool in tools {
            let name = tool.definition.function.name
            guard registeredTools[name] == nil else {
                throw ToolRuntimeError.duplicateTool(name)
            }
            registeredTools[name] = tool
        }

        self.tools = registeredTools
        self.outputLimitBytes = outputLimitBytes
    }

    public var definitions: [ToolDefinition] {
        tools.values
            .map(\.definition)
            .sorted { $0.function.name < $1.function.name }
    }

    public func isConcurrencySafe(_ call: ToolCall) -> Bool {
        guard let tool = tools[call.function.name] else {
            return false
        }
        return tool.isConcurrencySafe(arguments: call.function.arguments)
    }

    public func execute(_ call: ToolCall) async -> ToolExecution {
        let name = call.function.name
        guard let tool = tools[name] else {
            return ToolExecution(
                name: name,
                arguments: call.function.arguments,
                content: errorContent(code: "unknown_tool", message: ToolRuntimeError.unknownTool(name).localizedDescription),
                succeeded: false
            )
        }

        do {
            let content = try await tool.execute(arguments: call.function.arguments)
            return ToolExecution(
                name: name,
                arguments: call.function.arguments,
                content: Self.boundedContent(content, limitBytes: outputLimitBytes),
                succeeded: true
            )
        } catch {
            return ToolExecution(
                name: name,
                arguments: call.function.arguments,
                content: errorContent(code: "tool_failed", message: error.localizedDescription),
                succeeded: false
            )
        }
    }

    private func errorContent(code: String, message: String) -> String {
        let payload: [String: String] = [
            "error": code,
            "message": message
        ]
        guard let data = try? JSONEncoder().encode(payload) else {
            return "{\"error\":\"tool_failed\"}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Truncates oversized tool output on a UTF-8 boundary so a single result can
    /// never overflow the model context, appending a marker the model can see.
    static func boundedContent(_ content: String, limitBytes: Int) -> String {
        guard content.lengthOfBytes(using: .utf8) > limitBytes else {
            return content
        }
        let marker = "\n…[truncated]"
        let budget = max(0, limitBytes - marker.lengthOfBytes(using: .utf8))
        var truncated = content
        while truncated.lengthOfBytes(using: .utf8) > budget, !truncated.isEmpty {
            truncated.removeLast()
        }
        return truncated + marker
    }
}