import Foundation
import Testing
@testable import LLMCore

@Suite("Tool Runtime")
struct ToolRuntimeTests {
    @Test("advertises registered capability schemas")
    func advertisesDefinitions() async throws {
        let runtime = try ToolRuntime(tools: [TestTool()])
        let definitions = await runtime.definitions

        #expect(definitions.count == 1)
        #expect(definitions[0].type == "function")
        #expect(definitions[0].function.name == "web")
    }

    @Test("passes model arguments to the registered implementation")
    func executesWithArguments() async throws {
        let tool = TestTool()
        let runtime = try ToolRuntime(tools: [tool])
        let call = ToolCall(
            function: ToolFunctionCall(
                index: 0,
                name: "web",
                arguments: [
                    "action": .string("search"),
                    "query": .string("Suzhou weather"),
                    "maximum_results": .number(3)
                ]
            )
        )

        let execution = await runtime.execute(call)
        let receivedArguments = await tool.receivedArguments

        #expect(execution.succeeded)
        #expect(execution.name == "web")
        #expect(execution.arguments == call.function.arguments)
        #expect(execution.content == "fixture result")
        #expect(receivedArguments == call.function.arguments)
    }

    @Test("rejects duplicate model-facing tool names")
    func rejectsDuplicateNames() async throws {
        let first = TestTool()
        let second = TestTool()

        #expect(throws: ToolRuntimeError.duplicateTool("web")) {
            try ToolRuntime(
                tools: [
                    first,
                    second
                ]
            )
        }
    }

    @Test("truncates oversized tool output on a UTF-8 boundary instead of failing")
    func truncatesOversizedOutput() async throws {
        let limit = 64
        let runtime = try ToolRuntime(tools: [OversizedTool()], outputLimitBytes: limit)
        let call = ToolCall(
            function: ToolFunctionCall(index: 0, name: "oversized", arguments: [:])
        )

        let execution = await runtime.execute(call)

        #expect(execution.succeeded)
        #expect(execution.content.lengthOfBytes(using: .utf8) <= limit)
        #expect(execution.content.hasSuffix("…[truncated]"))
        // Valid UTF-8 (no split multibyte character) — round-trips through Data.
        #expect(String(data: Data(execution.content.utf8), encoding: .utf8) == execution.content)
    }

    @Test("leaves output within the limit unchanged")
    func keepsSmallOutput() async throws {
        let runtime = try ToolRuntime(tools: [TestTool()], outputLimitBytes: 1_024)
        let call = ToolCall(
            function: ToolFunctionCall(index: 0, name: "web", arguments: [:])
        )
        let execution = await runtime.execute(call)
        #expect(execution.content == "fixture result")
    }

    @Test("forwards tool diagnostics through the active run context")
    func forwardsDiagnostics() async throws {
        let runtime = try ToolRuntime(tools: [DiagnosticTool()])
        let recorder = DiagnosticRecorder()
        let call = ToolCall(
            function: ToolFunctionCall(index: 0, name: "diagnostic", arguments: [:])
        )

        let execution = await ToolDiagnostics.$handler.withValue({ diagnostic in
            await recorder.append(diagnostic)
        }) {
            await runtime.execute(call)
        }

        let diagnostics = await recorder.values
        #expect(execution.succeeded)
        #expect(diagnostics.count == 1)
        #expect(diagnostics[0].event == "tool.phase")
        #expect(diagnostics[0].level == "warning")
        #expect(diagnostics[0].data == ["status": "waiting"])
    }
}

private actor TestTool: LLMTool {
    nonisolated let definition = ToolDefinition(
        function: ToolFunctionDefinition(
            name: "web",
            description: "Fixture capability used only by ToolRuntime tests.",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "action": .object(["type": .string("string")]),
                    "query": .object(["type": .string("string")]),
                    "maximum_results": .object(["type": .string("integer")])
                ])
            ])
        )
    )
    private(set) var receivedArguments: [String: JSONValue]?

    func execute(arguments: [String: JSONValue]) async throws -> String {
        receivedArguments = arguments
        return "fixture result"
    }
}

private actor DiagnosticTool: LLMTool {
    nonisolated let definition = ToolDefinition(
        function: ToolFunctionDefinition(
            name: "diagnostic",
            description: "Emits one diagnostic event.",
            parameters: .object(["type": .string("object")])
        )
    )

    func execute(arguments: [String: JSONValue]) async throws -> String {
        await ToolDiagnostics.record(
            "tool.phase",
            level: "warning",
            data: ["status": "waiting"]
        )
        return "done"
    }
}

private actor DiagnosticRecorder {
    private(set) var values: [ToolDiagnostic] = []

    func append(_ diagnostic: ToolDiagnostic) {
        values.append(diagnostic)
    }
}

private actor OversizedTool: LLMTool {
    nonisolated let definition = ToolDefinition(
        function: ToolFunctionDefinition(
            name: "oversized",
            description: "Returns output larger than the runtime limit, ending in a multibyte character.",
            parameters: .object(["type": .string("object")])
        )
    )

    func execute(arguments: [String: JSONValue]) async throws -> String {
        // Multibyte characters make the truncation boundary meaningful.
        String(repeating: "苏", count: 200)
    }
}