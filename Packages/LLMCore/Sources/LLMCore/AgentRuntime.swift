import Foundation

public struct AgentConfiguration: Equatable, Sendable {
    public let model: String
    public let systemPrompt: String
    public let keepAlive: String
    public let options: ModelOptions
    public let think: Bool
    public let maximumToolRounds: Int
    public let maximumToolCallsPerRound: Int
    public let maximumToolCallsTotal: Int
    public let repeatedToolFailureLimit: Int
    public let maximumResponseBytes: Int
    public let automaticallyWarmsUp: Bool

    public init(
        model: String,
        keepAlive: String = "30m",
        options: ModelOptions = ModelOptions(),
        think: Bool = false,
        maximumToolRounds: Int = 8,
        maximumToolCallsPerRound: Int = 4,
        maximumToolCallsTotal: Int = 8,
        repeatedToolFailureLimit: Int = 3,
        maximumResponseBytes: Int = 1_048_576,
        automaticallyWarmsUp: Bool = true
    ) {
        self.model = model
        self.systemPrompt = LLMCoreSystemPrompt.current
        self.keepAlive = keepAlive
        self.options = options
        self.think = think
        self.maximumToolRounds = maximumToolRounds
        self.maximumToolCallsPerRound = maximumToolCallsPerRound
        self.maximumToolCallsTotal = maximumToolCallsTotal
        self.repeatedToolFailureLimit = repeatedToolFailureLimit
        self.maximumResponseBytes = maximumResponseBytes
        self.automaticallyWarmsUp = automaticallyWarmsUp
    }
}

public struct AgentPerformance: Equatable, Sendable {
    public let timeToFirstEventSeconds: Double?
    public let timeToFirstTextSeconds: Double?
    public let totalSeconds: Double
    public let modelRequestCount: Int
    public let toolCallCount: Int
    public let modelUsage: [ModelUsage]

    public init(
        timeToFirstEventSeconds: Double?,
        timeToFirstTextSeconds: Double?,
        totalSeconds: Double,
        modelRequestCount: Int,
        toolCallCount: Int,
        modelUsage: [ModelUsage]
    ) {
        self.timeToFirstEventSeconds = timeToFirstEventSeconds
        self.timeToFirstTextSeconds = timeToFirstTextSeconds
        self.totalSeconds = totalSeconds
        self.modelRequestCount = modelRequestCount
        self.toolCallCount = toolCallCount
        self.modelUsage = modelUsage
    }
}

public enum AgentEvent: Equatable, Sendable {
    case modelRequestStarted(round: Int)
    case modelRequestFinished(round: Int, usage: ModelUsage)
    case thinking(String)
    case text(String)
    case toolCallsProposed(round: Int, calls: [ToolCall])
    case toolStarted(name: String, arguments: [String: JSONValue])
    case toolFinished(ToolExecution)
    case contextTrimmed(droppedMessages: Int, approximateBytesBefore: Int, approximateBytesAfter: Int)
}

public struct AgentResult: Equatable, Sendable {
    public let text: String
    public let messages: [ChatMessage]
    public let performance: AgentPerformance

    public init(text: String, messages: [ChatMessage], performance: AgentPerformance) {
        self.text = text
        self.messages = messages
        self.performance = performance
    }
}

public enum AgentRuntimeError: Error, Equatable, LocalizedError, Sendable {
    case emptyPrompt
    case toolRoundLimitExceeded(Int)
    case toolCallLimitExceeded(perRound: Int, total: Int)
    case repeatedToolFailure(name: String, attempts: Int)
    case responseTooLarge(Int)
    case streamEndedWithoutCompletion

    public var errorDescription: String? {
        switch self {
        case .emptyPrompt:
            "The prompt must not be empty."
        case .toolRoundLimitExceeded(let limit):
            "The model exceeded the limit of \(limit) tool rounds."
        case .toolCallLimitExceeded(let perRound, let total):
            "The model exceeded the tool-call budget (\(perRound) per round, \(total) total)."
        case .repeatedToolFailure(let name, let attempts):
            "Tool '\(name)' failed with identical arguments \(attempts) times."
        case .responseTooLarge(let limit):
            "The model response exceeded the \(limit)-byte limit."
        case .streamEndedWithoutCompletion:
            "The model stream ended without a completion event."
        }
    }
}

public actor AgentRuntime {
    public typealias EventHandler = @Sendable (AgentEvent) async -> Void

    private let provider: any ModelProvider
    private let toolRuntime: ToolRuntime
    private let configuration: AgentConfiguration
    private var warmupTask: Task<WarmupMetrics, any Error>?

    public init(
        provider: any ModelProvider,
        toolRuntime: ToolRuntime,
        configuration: AgentConfiguration
    ) {
        self.provider = provider
        self.toolRuntime = toolRuntime
        self.configuration = configuration
    }

    public func warmUp() async throws -> WarmupMetrics {
        if let warmupTask {
            return try await warmupTask.value
        }
        let task = Task { [provider, toolRuntime, configuration] in
            let clock = ContinuousClock()
            let start = clock.now
            let modelWarmup = try await provider.warmUp(
                model: configuration.model,
                keepAlive: configuration.keepAlive,
                options: configuration.options
            )
            let toolDefinitions = await toolRuntime.definitions
            let prefixUsage = try await Self.prewarmStablePrefix(
                provider: provider,
                configuration: configuration,
                toolDefinitions: toolDefinitions
            )
            return WarmupMetrics(
                elapsedSeconds: elapsedSeconds(since: start, clock: clock),
                providerLoadSeconds: modelWarmup.providerLoadSeconds,
                prefixPromptTokenCount: prefixUsage.promptTokenCount,
                prefixPromptSeconds: prefixUsage.promptDurationNanoseconds.map {
                    Double($0) / 1_000_000_000
                }
            )
        }
        warmupTask = task
        do {
            return try await task.value
        } catch {
            warmupTask = nil
            throw error
        }
    }

    private static func prewarmStablePrefix(
        provider: any ModelProvider,
        configuration: AgentConfiguration,
        toolDefinitions: [ToolDefinition]
    ) async throws -> ModelUsage {
        let request = ModelRequest(
            model: configuration.model,
            messages: [
                ChatMessage(role: .system, content: configuration.systemPrompt),
                ChatMessage(
                    role: .user,
                    content: "Initialize the stable instruction prefix. Do not call tools."
                )
            ],
            tools: toolDefinitions,
            think: false,
            keepAlive: configuration.keepAlive,
            options: ModelOptions(
                numContext: configuration.options.numContext,
                temperature: configuration.options.temperature,
                numPredict: 1
            )
        )
        let stream = try await provider.stream(request)
        var usage: ModelUsage?

        for try await event in stream {
            try Task.checkCancellation()
            if case .completed(let completedUsage) = event {
                usage = completedUsage
            }
        }

        guard let usage else {
            throw AgentRuntimeError.streamEndedWithoutCompletion
        }
        return usage
    }

    public func run(
        prompt: String,
        history: [ChatMessage] = [],
        onEvent: @escaping EventHandler = { _ in }
    ) async throws -> AgentResult {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw AgentRuntimeError.emptyPrompt
        }
        if configuration.automaticallyWarmsUp {
            _ = try await warmUp()
        }

        let clock = ContinuousClock()
        let start = clock.now
        var firstEventSeconds: Double?
        var firstTextSeconds: Double?
        var modelRequestCount = 0
        var toolCallCount = 0
        var failedCallCounts: [String: Int] = [:]
        var usages: [ModelUsage] = []
        var messages = [ChatMessage(role: .system, content: configuration.systemPrompt)]
        messages.append(contentsOf: history.filter { $0.role != .system })
        messages.append(ChatMessage(role: .user, content: trimmedPrompt))
        let toolDefinitions = await toolRuntime.definitions

        // Reserve part of the context window for generation and chat-template overhead.
        let contextBudgetBytes = Int(Double(configuration.options.numContext) * 3.0 * 0.6)

        for round in 0...configuration.maximumToolRounds {
            try Task.checkCancellation()
            modelRequestCount += 1
            await onEvent(.modelRequestStarted(round: round))

            let trim = trimMessagesToBudget(messages, budgetBytes: contextBudgetBytes)
            if trim.didTrim {
                await onEvent(.contextTrimmed(
                    droppedMessages: trim.droppedCount,
                    approximateBytesBefore: trim.bytesBefore,
                    approximateBytesAfter: trim.bytesAfter
                ))
            }

            let request = ModelRequest(
                model: configuration.model,
                messages: trim.messages,
                tools: toolCallCount < configuration.maximumToolCallsTotal ? toolDefinitions : [],
                think: configuration.think,
                keepAlive: configuration.keepAlive,
                options: configuration.options
            )

            let stream = try await provider.stream(request)
            var responseText = ""
            var responseThinking = ""
            var proposedCalls: [ToolCall] = []
            var completed = false

            for try await event in stream {
                try Task.checkCancellation()
                if firstEventSeconds == nil {
                    firstEventSeconds = elapsedSeconds(since: start, clock: clock)
                }

                switch event {
                case .text(let text):
                    if firstTextSeconds == nil {
                        firstTextSeconds = elapsedSeconds(since: start, clock: clock)
                    }
                    responseText += text
                    guard responseText.lengthOfBytes(using: .utf8) <= configuration.maximumResponseBytes else {
                        throw AgentRuntimeError.responseTooLarge(configuration.maximumResponseBytes)
                    }
                    await onEvent(.text(text))
                case .thinking(let thinking):
                    responseThinking += thinking
                    await onEvent(.thinking(thinking))
                case .toolCalls(let calls):
                    proposedCalls.append(contentsOf: calls)
                    await onEvent(.toolCallsProposed(round: round, calls: calls))
                case .completed(let usage):
                    usages.append(usage)
                    completed = true
                    await onEvent(.modelRequestFinished(round: round, usage: usage))
                }
            }

            guard completed else {
                throw AgentRuntimeError.streamEndedWithoutCompletion
            }

            messages.append(
                ChatMessage(
                    role: .assistant,
                    content: responseText,
                    thinking: responseThinking.isEmpty ? nil : responseThinking,
                    toolCalls: proposedCalls.isEmpty ? nil : proposedCalls
                )
            )

            guard !proposedCalls.isEmpty else {
                return AgentResult(
                    text: responseText,
                    messages: messages,
                    performance: AgentPerformance(
                        timeToFirstEventSeconds: firstEventSeconds,
                        timeToFirstTextSeconds: firstTextSeconds,
                        totalSeconds: elapsedSeconds(since: start, clock: clock),
                        modelRequestCount: modelRequestCount,
                        toolCallCount: toolCallCount,
                        modelUsage: usages
                    )
                )
            }

            guard proposedCalls.count <= configuration.maximumToolCallsPerRound,
                  toolCallCount + proposedCalls.count <= configuration.maximumToolCallsTotal
            else {
                throw AgentRuntimeError.toolCallLimitExceeded(
                    perRound: configuration.maximumToolCallsPerRound,
                    total: configuration.maximumToolCallsTotal
                )
            }

            guard round < configuration.maximumToolRounds else {
                throw AgentRuntimeError.toolRoundLimitExceeded(configuration.maximumToolRounds)
            }

            toolCallCount += proposedCalls.count
            let batches = await makeToolBatches(proposedCalls)
            var executions: [ToolExecution] = []

            for batch in batches {
                for item in batch.items {
                    await onEvent(
                        .toolStarted(
                            name: item.call.function.name,
                            arguments: item.call.function.arguments
                        )
                    )
                }

                if batch.concurrent {
                    let toolRuntime = self.toolRuntime
                    let batchExecutions = await withTaskGroup(
                        of: (Int, ToolExecution).self,
                        returning: [ToolExecution].self
                    ) { group in
                        for item in batch.items {
                            group.addTask {
                                (item.index, await toolRuntime.execute(item.call))
                            }
                        }

                        var indexedExecutions: [(Int, ToolExecution)] = []
                        for await execution in group {
                            indexedExecutions.append(execution)
                        }
                        return indexedExecutions
                            .sorted { $0.0 < $1.0 }
                            .map(\.1)
                    }
                    executions.append(contentsOf: batchExecutions)
                } else if let item = batch.items.first {
                    executions.append(await toolRuntime.execute(item.call))
                }
            }

            for (call, execution) in zip(proposedCalls, executions) {
                await onEvent(.toolFinished(execution))
                messages.append(
                    ChatMessage(
                        role: .tool,
                        content: execution.content,
                        toolName: execution.name
                    )
                )

                let signature = toolCallSignature(call)
                if execution.succeeded {
                    failedCallCounts[signature] = nil
                } else {
                    let attempts = failedCallCounts[signature, default: 0] + 1
                    failedCallCounts[signature] = attempts
                    if attempts >= configuration.repeatedToolFailureLimit {
                        throw AgentRuntimeError.repeatedToolFailure(
                            name: execution.name,
                            attempts: attempts
                        )
                    }
                }
            }
        }

        throw AgentRuntimeError.toolRoundLimitExceeded(configuration.maximumToolRounds)
    }

    private func makeToolBatches(_ calls: [ToolCall]) async -> [ToolBatch] {
        var batches: [ToolBatch] = []

        for (index, call) in calls.enumerated() {
            let item = IndexedToolCall(index: index, call: call)
            let concurrencySafe = await toolRuntime.isConcurrencySafe(call)
            if concurrencySafe, batches.last?.concurrent == true {
                batches[batches.count - 1].items.append(item)
            } else {
                batches.append(
                    ToolBatch(concurrent: concurrencySafe, items: [item])
                )
            }
        }
        return batches
    }
}

private struct IndexedToolCall: Sendable {
    let index: Int
    let call: ToolCall
}

private struct ToolBatch: Sendable {
    let concurrent: Bool
    var items: [IndexedToolCall]
}

private func elapsedSeconds(since start: ContinuousClock.Instant, clock: ContinuousClock) -> Double {
    let components = start.duration(to: clock.now).components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
}

private func toolCallSignature(_ call: ToolCall) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(call) else {
        return call.function.name
    }
    return String(decoding: data, as: UTF8.self)
}

struct ContextTrimResult: Equatable {
    let messages: [ChatMessage]
    let droppedCount: Int
    let bytesBefore: Int
    let bytesAfter: Int
    var didTrim: Bool { droppedCount > 0 }
}

/// Keeps the request within the context budget while guaranteeing the system prompt
/// and the first user query are never dropped, so the model always sees the task.
/// Older middle messages (tool results, earlier turns) are removed first, newest kept.
func trimMessagesToBudget(_ messages: [ChatMessage], budgetBytes: Int) -> ContextTrimResult {
    func bytes(_ message: ChatMessage) -> Int {
        var total = message.content.lengthOfBytes(using: .utf8) + message.role.rawValue.count + 8
        if let thinking = message.thinking {
            total += thinking.lengthOfBytes(using: .utf8)
        }
        if let toolCalls = message.toolCalls,
           let data = try? JSONEncoder().encode(toolCalls) {
            total += data.count
        }
        if let toolName = message.toolName {
            total += toolName.count
        }
        return total
    }

    let bytesBefore = messages.reduce(0) { $0 + bytes($1) }
    guard bytesBefore > budgetBytes else {
        return ContextTrimResult(
            messages: messages,
            droppedCount: 0,
            bytesBefore: bytesBefore,
            bytesAfter: bytesBefore
        )
    }

    // Protected: system prompt (if first) and the first user message — the task itself.
    var protectedIndices = Set<Int>()
    if let first = messages.first, first.role == .system {
        protectedIndices.insert(0)
    }
    if let firstUser = messages.firstIndex(where: { $0.role == .user }) {
        protectedIndices.insert(firstUser)
    }

    var kept = protectedIndices
    var used = protectedIndices.reduce(0) { $0 + bytes(messages[$1]) }

    // Add newest-to-oldest until the budget is exhausted.
    for index in stride(from: messages.count - 1, through: 0, by: -1) where !kept.contains(index) {
        let cost = bytes(messages[index])
        if used + cost <= budgetBytes {
            kept.insert(index)
            used += cost
        }
    }

    let trimmed = messages.enumerated()
        .filter { kept.contains($0.offset) }
        .map(\.element)
    let bytesAfter = trimmed.reduce(0) { $0 + bytes($1) }

    return ContextTrimResult(
        messages: trimmed,
        droppedCount: messages.count - trimmed.count,
        bytesBefore: bytesBefore,
        bytesAfter: bytesAfter
    )
}