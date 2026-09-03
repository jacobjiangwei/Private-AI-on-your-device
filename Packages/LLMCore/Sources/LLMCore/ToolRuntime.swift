import Foundation

public protocol LLMTool: Sendable {
    var definition: ToolDefinition { get }
    func isConcurrencySafe(arguments: [String: JSONValue]) -> Bool
    func stabilizedArguments(
        _ arguments: [String: JSONValue],
        previousArguments: [[String: JSONValue]]
    ) -> [String: JSONValue]
    func canonicalArgumentsForStabilization(
        _ arguments: [String: JSONValue]
    ) -> [String: JSONValue]?
    func execute(arguments: [String: JSONValue]) async throws -> String
}

public extension LLMTool {
    func isConcurrencySafe(arguments: [String: JSONValue]) -> Bool {
        false
    }

    func stabilizedArguments(
        _ arguments: [String: JSONValue],
        previousArguments: [[String: JSONValue]]
    ) -> [String: JSONValue] {
        arguments
    }

    func canonicalArgumentsForStabilization(
        _ arguments: [String: JSONValue]
    ) -> [String: JSONValue]? {
        nil
    }
}

public enum ToolRuntimeError: Error, Equatable, LocalizedError, Sendable {
    case duplicateTool(String)
    case invalidOutputLimit(Int)
    case unknownTool(String)

    public var errorDescription: String? {
        switch self {
        case .duplicateTool(let name):
            "A tool named '\(name)' is already registered."
        case .invalidOutputLimit(let limit):
            "The Tool output limit must be at least 32 bytes, not \(limit)."
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
    private let serialGates: [String: ToolSerialGate]
    private let outputLimitBytes: Int

    public init(tools: [any LLMTool], outputLimitBytes: Int = 16 * 1_024) throws {
        guard outputLimitBytes >= 32 else {
            throw ToolRuntimeError.invalidOutputLimit(outputLimitBytes)
        }
        var registeredTools: [String: any LLMTool] = [:]
        for tool in tools {
            let name = tool.definition.function.name
            guard registeredTools[name] == nil else {
                throw ToolRuntimeError.duplicateTool(name)
            }
            registeredTools[name] = tool
        }

        self.tools = registeredTools
    self.serialGates = registeredTools.mapValues { _ in ToolSerialGate() }
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

    public func stabilizedCall(
        _ call: ToolCall,
        previousArguments: [[String: JSONValue]]
    ) -> ToolCall {
        guard let tool = tools[call.function.name] else { return call }
        return ToolCall(
            type: call.type,
            function: ToolFunctionCall(
                index: call.function.index,
                name: call.function.name,
                arguments: tool.stabilizedArguments(
                    call.function.arguments,
                    previousArguments: previousArguments
                )
            )
        )
    }

    public func canonicalArgumentsForStabilization(
        _ call: ToolCall
    ) -> [String: JSONValue]? {
        tools[call.function.name]?.canonicalArgumentsForStabilization(
            call.function.arguments
        )
    }

    public func execute(_ call: ToolCall) async -> ToolExecution {
        let name = call.function.name
        guard let tool = tools[name] else {
            return ToolExecution(
                name: name,
                arguments: call.function.arguments,
                content: errorContent(
                    code: "unknown_tool",
                    message: ToolRuntimeError.unknownTool(name).localizedDescription
                ),
                succeeded: false
            )
        }

        if !tool.isConcurrencySafe(arguments: call.function.arguments),
           let gate = serialGates[name] {
            do {
                try await gate.acquire()
            } catch {
                return failedExecution(call: call, error: error)
            }
            if Task.isCancelled {
                await gate.release()
                return failedExecution(call: call, error: CancellationError())
            }
            let execution = await execute(tool: tool, call: call)
            await gate.release()
            return execution
        }
        return await execute(tool: tool, call: call)
    }

    private func execute(tool: any LLMTool, call: ToolCall) async -> ToolExecution {
        do {
            let content = try await tool.execute(arguments: call.function.arguments)
            return ToolExecution(
                name: call.function.name,
                arguments: call.function.arguments,
                content: Self.boundedContent(content, limitBytes: outputLimitBytes),
                succeeded: true
            )
        } catch {
            return failedExecution(call: call, error: error)
        }
    }

    private func failedExecution(call: ToolCall, error: any Error) -> ToolExecution {
        ToolExecution(
            name: call.function.name,
            arguments: call.function.arguments,
            content: errorContent(code: "tool_failed", message: error.localizedDescription),
            succeeded: false
        )
    }

    private func errorContent(code: String, message: String) -> String {
        func encoded(_ value: String) -> Data? {
            try? JSONEncoder().encode([
                "error": code,
                "message": value
            ])
        }
        if let data = encoded(message), data.count <= outputLimitBytes {
            return String(decoding: data, as: UTF8.self)
        }
        let bytes = Array(message.utf8)
        var prefixCount = min(bytes.count, outputLimitBytes / 2)
        while prefixCount > 0 {
            let candidate = String(decoding: bytes.prefix(prefixCount), as: UTF8.self)
                + "...[truncated]"
            if let data = encoded(candidate), data.count <= outputLimitBytes {
                return String(decoding: data, as: UTF8.self)
            }
            prefixCount /= 2
        }
        return "{\"error\":\"tool_failed\"}"
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

private actor ToolSerialGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var isAcquired = false
    private var waiters: [Waiter] = []

    func acquire() async throws {
        try Task.checkCancellation()
        guard isAcquired else {
            isAcquired = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    func release() {
        if waiters.isEmpty {
            isAcquired = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}