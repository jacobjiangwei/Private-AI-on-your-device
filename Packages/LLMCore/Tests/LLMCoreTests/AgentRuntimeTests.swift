import Foundation
import Testing
@testable import LLMCore

@Suite("Agent Runtime")
struct AgentRuntimeTests {
    @Test("encodes permanent Ollama keep alive as a JSON number")
    func permanentKeepAliveEncoding() throws {
        let request = ModelRequest(
            model: "fixture",
            messages: [ChatMessage(role: .user, content: "Hello")],
            keepAlive: "-1"
        )
        let data = try JSONEncoder().encode(request)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["keep_alive"] as? Int == -1)
    }

    @Test("automatically warms once before the first chat request")
    func automaticallyWarmsOnce() async throws {
        let provider = ScriptedProvider(responses: [
            [.completed(ModelUsage(promptTokenCount: 42))],
            [.text("First answer"), .completed(ModelUsage())],
            [.text("Second answer"), .completed(ModelUsage())]
        ])
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: []),
            configuration: AgentConfiguration(model: "fixture")
        )

        let first = try await runtime.run(prompt: "First question")
        let second = try await runtime.run(prompt: "Second question")
        let requests = await provider.recordedRequests

        #expect(first.text == "First answer")
        #expect(second.text == "Second answer")
        #expect(await provider.warmupCount == 1)
        #expect(requests.count == 3)
        #expect(requests[0].messages.last?.content.contains("stable instruction prefix") == true)
        #expect(requests[1].messages.last?.content == "First question")
        #expect(requests[2].messages.last?.content == "Second question")
    }

    @Test("executes a model-selected tool and returns its result to the model")
    func executesToolLoop() async throws {
        let call = ToolCall(
            function: ToolFunctionCall(
                name: "web",
                arguments: [
                    "action": .string("search"),
                    "query": .string("Suzhou current weather")
                ]
            )
        )
        let provider = ScriptedProvider(responses: [
            [.toolCalls([call]), .completed(ModelUsage())],
            [.text("Suzhou is 24 C and clear."), .completed(ModelUsage())]
        ])
        let tools = try ToolRuntime(tools: [FixtureTool()])
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: tools,
            configuration: AgentConfiguration(model: "fixture", automaticallyWarmsUp: false)
        )

        let result = try await runtime.run(prompt: "What is the weather in Suzhou?")
        let requests = await provider.recordedRequests

        #expect(result.text == "Suzhou is 24 C and clear.")
        #expect(result.performance.modelRequestCount == 2)
        #expect(result.performance.toolCallCount == 1)
        #expect(requests.count == 2)
        #expect(requests[0].tools.map(\.function.name) == ["web"])
        #expect(requests[1].messages.last?.role == .tool)
        #expect(requests[1].messages.last?.toolName == "web")
        #expect(requests[1].messages.last?.content.contains("24") == true)
    }

    @Test("returns unknown tool failures to the model without executing them")
    func containsUnknownTool() async throws {
        let call = ToolCall(
            function: ToolFunctionCall(name: "unregistered", arguments: [:])
        )
        let provider = ScriptedProvider(responses: [
            [.toolCalls([call]), .completed(ModelUsage())],
            [.text("That tool is unavailable."), .completed(ModelUsage())]
        ])
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: []),
            configuration: AgentConfiguration(model: "fixture", automaticallyWarmsUp: false)
        )

        let result = try await runtime.run(prompt: "Use an unavailable tool")
        let requests = await provider.recordedRequests

        #expect(result.text == "That tool is unavailable.")
        #expect(requests[1].messages.last?.content.contains("unknown_tool") == true)
    }

    @Test("rejects empty prompts before contacting the provider")
    func rejectsEmptyPrompt() async throws {
        let provider = ScriptedProvider(responses: [])
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: []),
            configuration: AgentConfiguration(model: "fixture", automaticallyWarmsUp: false)
        )

        await #expect(throws: AgentRuntimeError.emptyPrompt) {
            try await runtime.run(prompt: "  \n")
        }
        #expect(await provider.recordedRequests.isEmpty)
    }

    @Test("includes prior conversation messages before the new user prompt")
    func includesConversationHistory() async throws {
        let provider = ScriptedProvider(responses: [
            [.text("Current answer"), .completed(ModelUsage())]
        ])
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: []),
            configuration: AgentConfiguration(model: "fixture", automaticallyWarmsUp: false)
        )
        let history = [
            ChatMessage(role: .user, content: "Earlier question"),
            ChatMessage(role: .assistant, content: "Earlier answer")
        ]

        _ = try await runtime.run(prompt: "Current question", history: history)
        let request = try #require(await provider.recordedRequests.first)

        #expect(request.messages.map(\.role) == [.system, .user, .assistant, .user])
        #expect(request.messages.map(\.content) == [
            LLMCoreSystemPrompt.current,
            "Earlier question",
            "Earlier answer",
            "Current question"
        ])
    }

    @Test("rejects a tool-call batch before partially executing it")
    func enforcesToolCallBudget() async throws {
        let calls = [
            ToolCall(function: ToolFunctionCall(name: "web", arguments: ["action": .string("search"), "query": .string("one")])),
            ToolCall(function: ToolFunctionCall(name: "web", arguments: ["action": .string("search"), "query": .string("two")]))
        ]
        let provider = ScriptedProvider(responses: [
            [.toolCalls(calls), .completed(ModelUsage())]
        ])
        let tool = RecordingTool()
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: [tool]),
            configuration: AgentConfiguration(
                model: "fixture",
                maximumToolCallsPerRound: 1,
                maximumToolCallsTotal: 1,
                automaticallyWarmsUp: false
            )
        )

        await #expect(throws: AgentRuntimeError.toolCallLimitExceeded(perRound: 1, total: 1)) {
            try await runtime.run(prompt: "Search twice")
        }
        #expect(await tool.executionCount == 0)
    }

    @Test("executes tool calls from one model response concurrently")
    func executesParallelToolBatch() async throws {
        let calls = [
            ToolCall(function: ToolFunctionCall(index: 0, name: "probe", arguments: ["value": .string("first")])),
            ToolCall(function: ToolFunctionCall(index: 1, name: "probe", arguments: ["value": .string("second")]))
        ]
        let provider = ScriptedProvider(responses: [
            [.toolCalls(calls), .completed(ModelUsage())],
            [.text("done"), .completed(ModelUsage())]
        ])
        let tool = ParallelProbeTool()
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: [tool]),
            configuration: AgentConfiguration(model: "fixture", automaticallyWarmsUp: false)
        )

        let result = try await runtime.run(prompt: "Run both probes")
        let maximumConcurrency = await tool.maximumConcurrency
        let requests = await provider.recordedRequests

        #expect(result.text == "done")
        #expect(maximumConcurrency == 2)
        #expect(requests[1].messages.suffix(2).map(\.content) == ["first", "second"])
    }

    @Test("executes tools serially unless the implementation opts into concurrency")
    func defaultsToolBatchToSerial() async throws {
        let calls = [
            ToolCall(function: ToolFunctionCall(index: 0, name: "serial_probe", arguments: ["value": .string("first")])),
            ToolCall(function: ToolFunctionCall(index: 1, name: "serial_probe", arguments: ["value": .string("second")]))
        ]
        let provider = ScriptedProvider(responses: [
            [.toolCalls(calls), .completed(ModelUsage())],
            [.text("done"), .completed(ModelUsage())]
        ])
        let tool = SerialProbeTool()
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: [tool]),
            configuration: AgentConfiguration(model: "fixture", automaticallyWarmsUp: false)
        )

        _ = try await runtime.run(prompt: "Run both probes")

        #expect(await tool.maximumConcurrency == 1)
    }

    @Test("stops an identical failed tool-call loop")
    func stopsRepeatedFailureLoop() async throws {
        let call = ToolCall(
            function: ToolFunctionCall(
                index: 0,
                name: "always_fails",
                arguments: ["value": .string("same")]
            )
        )
        let provider = ScriptedProvider(responses: Array(
            repeating: [.toolCalls([call]), .completed(ModelUsage())],
            count: 4
        ))
        let tool = AlwaysFailingTool()
        let runtime = AgentRuntime(
            provider: provider,
            toolRuntime: try ToolRuntime(tools: [tool]),
            configuration: AgentConfiguration(
                model: "fixture",
                repeatedToolFailureLimit: 3,
                automaticallyWarmsUp: false
            )
        )

        await #expect(
            throws: AgentRuntimeError.repeatedToolFailure(
                name: "always_fails",
                attempts: 3
            )
        ) {
            try await runtime.run(prompt: "Keep failing")
        }
        #expect(await tool.executionCount == 3)
        #expect(await provider.recordedRequests.count == 3)
    }
}

private struct FixtureTool: LLMTool {
    let definition = fixtureToolDefinition

    func execute(arguments: [String: JSONValue]) async throws -> String {
        "{\"city\":\"Suzhou\",\"temperature_celsius\":24,\"condition\":\"clear\"}"
    }
}

private actor RecordingTool: LLMTool {
    nonisolated let definition = fixtureToolDefinition
    private(set) var executionCount = 0

    func execute(arguments: [String: JSONValue]) async throws -> String {
        executionCount += 1
        return "{}"
    }
}

private actor ParallelProbeTool: LLMTool {
    nonisolated let definition = ToolDefinition(
        function: ToolFunctionDefinition(
            name: "probe",
            description: "Test concurrent execution.",
            parameters: .object(["type": .string("object")])
        )
    )
    private var activeCount = 0
    private(set) var maximumConcurrency = 0

    nonisolated func isConcurrencySafe(arguments: [String: JSONValue]) -> Bool {
        true
    }

    func execute(arguments: [String: JSONValue]) async throws -> String {
        activeCount += 1
        maximumConcurrency = max(maximumConcurrency, activeCount)
        try await ContinuousClock().sleep(for: .milliseconds(100))
        activeCount -= 1
        return arguments["value"]?.stringValue ?? ""
    }
}

private actor SerialProbeTool: LLMTool {
    nonisolated let definition = ToolDefinition(
        function: ToolFunctionDefinition(
            name: "serial_probe",
            description: "Test default serial execution.",
            parameters: .object(["type": .string("object")])
        )
    )
    private var activeCount = 0
    private(set) var maximumConcurrency = 0

    func execute(arguments: [String: JSONValue]) async throws -> String {
        activeCount += 1
        maximumConcurrency = max(maximumConcurrency, activeCount)
        try await ContinuousClock().sleep(for: .milliseconds(50))
        activeCount -= 1
        return arguments["value"]?.stringValue ?? ""
    }
}

private enum FixtureToolError: Error {
    case failed
}

private actor AlwaysFailingTool: LLMTool {
    nonisolated let definition = ToolDefinition(
        function: ToolFunctionDefinition(
            name: "always_fails",
            description: "Always fails for loop-guard testing.",
            parameters: .object(["type": .string("object")])
        )
    )
    private(set) var executionCount = 0

    func execute(arguments: [String: JSONValue]) async throws -> String {
        executionCount += 1
        throw FixtureToolError.failed
    }
}

private let fixtureToolDefinition = ToolDefinition(
    function: ToolFunctionDefinition(
        name: "web",
        description: "Fixture capability used only by tests.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "action": .object(["type": .string("string")]),
                "query": .object(["type": .string("string")])
            ]),
            "required": .array([.string("action"), .string("query")])
        ])
    )
)

private actor ScriptedProvider: ModelProvider {
    private var responses: [[ModelStreamEvent]]
    private(set) var recordedRequests: [ModelRequest] = []
    private(set) var warmupCount = 0

    init(responses: [[ModelStreamEvent]]) {
        self.responses = responses
    }

    func warmUp(
        model: String,
        keepAlive: String,
        options: ModelOptions
    ) async throws -> WarmupMetrics {
        warmupCount += 1
        return WarmupMetrics(elapsedSeconds: 0, providerLoadSeconds: 0)
    }

    func stream(
        _ request: ModelRequest
    ) async throws -> AsyncThrowingStream<ModelStreamEvent, any Error> {
        recordedRequests.append(request)
        let events = responses.removeFirst()
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}