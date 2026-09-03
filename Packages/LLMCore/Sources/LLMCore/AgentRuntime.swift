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
    case toolProgress(name: String, detail: String)
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
    case requiredContextTooLarge(required: Int, budget: Int)
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
        case .requiredContextTooLarge(let required, let budget):
            "The required system prompt and current task need approximately \(required) bytes, exceeding the \(budget)-byte context budget."
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
        var forceToolFreeFinalization = false
        var finalizationReminderAdded = false
        var finalizationCorrectionUsed = false
        var failedArgumentsByTool: [String: [[String: JSONValue]]] = [:]
        var messages = [ChatMessage(role: .system, content: configuration.systemPrompt)]
        messages.append(contentsOf: history.filter { $0.role != .system })
        let currentUserIndex = messages.count
        messages.append(ChatMessage(role: .user, content: trimmedPrompt))
        let toolDefinitions = await toolRuntime.definitions

        // Reserve part of the context window for generation and chat-template overhead.
        let contextBudgetBytes = Int(Double(configuration.options.numContext) * 3.0 * 0.6)

        for round in 0...(configuration.maximumToolRounds + 1) {
            try Task.checkCancellation()
            let shouldFinalizeWithoutTools = forceToolFreeFinalization
                || toolCallCount >= configuration.maximumToolCallsTotal
                || round >= configuration.maximumToolRounds
            if shouldFinalizeWithoutTools, !finalizationReminderAdded {
                messages[currentUserIndex] = ChatMessage(
                    role: .user,
                    content: trimmedPrompt + "\n\n" + toolBudgetFinalizationInstruction
                )
                finalizationReminderAdded = true
            }
            modelRequestCount += 1
            await onEvent(.modelRequestStarted(round: round))

            let trim = trimMessagesToBudget(messages, budgetBytes: contextBudgetBytes)
            if trim.requiredBytesExceededBudget {
                throw AgentRuntimeError.requiredContextTooLarge(
                    required: trim.requiredBytes,
                    budget: contextBudgetBytes
                )
            }
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
                tools: shouldFinalizeWithoutTools ? [] : toolDefinitions,
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

            guard !proposedCalls.isEmpty else {
                messages.append(ChatMessage(
                    role: .assistant,
                    content: responseText,
                    thinking: responseThinking.isEmpty ? nil : responseThinking
                ))
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

            var stabilizedCalls: [ToolCall] = []
            for call in proposedCalls {
                let name = call.function.name
                let stabilized = await toolRuntime.stabilizedCall(
                    call,
                    previousArguments: failedArgumentsByTool[name, default: []]
                )
                stabilizedCalls.append(stabilized)
            }
            proposedCalls = stabilizedCalls

            if shouldFinalizeWithoutTools {
                messages.append(ChatMessage(
                    role: .assistant,
                    content: responseText,
                    thinking: responseThinking.isEmpty ? nil : responseThinking
                ))
                guard !finalizationCorrectionUsed else {
                    throw AgentRuntimeError.toolCallLimitExceeded(
                        perRound: configuration.maximumToolCallsPerRound,
                        total: configuration.maximumToolCallsTotal
                    )
                }
                messages[currentUserIndex] = ChatMessage(
                    role: .user,
                    content: trimmedPrompt
                        + "\n\n"
                        + toolBudgetFinalizationInstruction
                        + "\n\n"
                        + toolBudgetCorrectionInstruction
                )
                forceToolFreeFinalization = true
                finalizationCorrectionUsed = true
                continue
            }

            guard proposedCalls.count <= configuration.maximumToolCallsPerRound else {
                throw AgentRuntimeError.toolCallLimitExceeded(
                    perRound: configuration.maximumToolCallsPerRound,
                    total: configuration.maximumToolCallsTotal
                )
            }

            if toolCallCount + proposedCalls.count > configuration.maximumToolCallsTotal {
                messages.append(ChatMessage(
                    role: .assistant,
                    content: responseText,
                    thinking: responseThinking.isEmpty ? nil : responseThinking
                ))
                messages[currentUserIndex] = ChatMessage(
                    role: .user,
                    content: trimmedPrompt + "\n\n" + toolBudgetFinalizationInstruction
                )
                forceToolFreeFinalization = true
                finalizationReminderAdded = true
                continue
            }

            messages.append(ChatMessage(
                role: .assistant,
                content: responseText,
                thinking: responseThinking.isEmpty ? nil : responseThinking,
                toolCalls: proposedCalls
            ))
            toolCallCount += proposedCalls.count
            let batches = await makeToolBatches(proposedCalls)

            for batch in batches {
                try Task.checkCancellation()
                for item in batch.items {
                    await onEvent(
                        .toolStarted(
                            name: item.call.function.name,
                            arguments: item.call.function.arguments
                        )
                    )
                }

                let batchExecutions: [ToolExecution]
                if batch.concurrent {
                    let toolRuntime = self.toolRuntime
                    batchExecutions = await withTaskGroup(
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
                } else if let item = batch.items.first {
                    batchExecutions = [await toolRuntime.execute(item.call)]
                } else {
                    batchExecutions = []
                }
                try Task.checkCancellation()

                for (item, execution) in zip(batch.items, batchExecutions) {
                    await onEvent(.toolFinished(execution))
                    messages.append(
                        ChatMessage(
                            role: .tool,
                            content: execution.content,
                            toolName: execution.name
                        )
                    )

                    let signature = toolCallSignature(item.call)
                    let canonical = await toolRuntime.canonicalArgumentsForStabilization(
                        item.call
                    )
                    if execution.succeeded {
                        failedCallCounts[signature] = nil
                        if let canonical {
                            failedArgumentsByTool[item.call.function.name]?.removeAll {
                                $0 == canonical
                            }
                        }
                    } else {
                        if let canonical,
                           failedArgumentsByTool[item.call.function.name, default: []]
                            .contains(canonical) == false {
                            failedArgumentsByTool[item.call.function.name, default: []]
                                .append(canonical)
                        }
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
        }

        throw AgentRuntimeError.toolRoundLimitExceeded(configuration.maximumToolRounds)
    }

    private func makeToolBatches(_ calls: [ToolCall]) async -> [ToolBatch] {
        var batches: [ToolBatch] = []

        for (index, call) in calls.enumerated() {
            let item = IndexedToolCall(index: index, call: call)
            let concurrencySafe = await toolRuntime.isConcurrencySafe(call)
            let signature = toolCallSignature(call)
            if concurrencySafe,
               batches.last?.concurrent == true,
               batches.last?.items.contains(where: {
                   toolCallSignature($0.call) == signature
               }) == false {
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

private let toolBudgetFinalizationInstruction = """
The tool-call budget for this run is exhausted. Do not call any tool. Answer the user's request now using only the evidence already gathered. Be explicit about any material limitation caused by incomplete evidence.
"""

private let toolBudgetCorrectionInstruction = """
The previous tool proposal could not be executed because the tool-call budget is exhausted. Do not propose or mention another tool call. Produce the best final answer now from the evidence already available, and state any important coverage limitation.
"""

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
    let value = JSONValue.object([
        "name": .string(call.function.name),
        "arguments": .object(call.function.arguments)
    ])
    guard let data = try? encoder.encode(value) else {
        return call.function.name
    }
    return String(decoding: data, as: UTF8.self)
}

struct ContextTrimResult: Equatable {
    let messages: [ChatMessage]
    let droppedCount: Int
    let bytesBefore: Int
    let bytesAfter: Int
    let requiredBytes: Int
    let requiredBytesExceededBudget: Bool
    var didTrim: Bool { droppedCount > 0 }
}

/// Keeps the request within the context budget while guaranteeing the system prompt
/// and current user query are never dropped, so the model always sees the active task.
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
            bytesAfter: bytesBefore,
            requiredBytes: 0,
            requiredBytesExceededBudget: false
        )
    }

    // Protected: system prompt (if first) and the last user message — the current task.
    var protectedIndices = Set<Int>()
    if let first = messages.first, first.role == .system {
        protectedIndices.insert(0)
    }
    if let currentUser = messages.lastIndex(where: { $0.role == .user }) {
        protectedIndices.insert(currentUser)
    }

    let groups = messageGroups(messages)
    let protectedGroups = groups.filter { group in
        !group.indices.isDisjoint(with: protectedIndices)
    }
    var kept = Set(protectedGroups.flatMap(\.indices))
    let requiredBytes = kept.reduce(0) { $0 + bytes(messages[$1]) }
    var used = requiredBytes

    // Add newest complete turns first. Tool proposals and their results are indivisible.
    for group in groups.reversed()
        where group.indices.isDisjoint(with: kept) {
        let cost = group.indices.reduce(0) { $0 + bytes(messages[$1]) }
        if used + cost <= budgetBytes {
            kept.formUnion(group.indices)
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
        bytesAfter: bytesAfter,
        requiredBytes: requiredBytes,
        requiredBytesExceededBudget: requiredBytes > budgetBytes
    )
}

private struct ContextMessageGroup {
    let indices: Set<Int>
}

private func messageGroups(_ messages: [ChatMessage]) -> [ContextMessageGroup] {
    var groups: [ContextMessageGroup] = []
    var index = 0
    while index < messages.count {
        let message = messages[index]
        if message.role == .assistant, let calls = message.toolCalls, !calls.isEmpty {
            var indices: Set<Int> = [index]
            var next = index + 1
            var remainingResults = calls.count
            while next < messages.count,
                  remainingResults > 0,
                  messages[next].role == .tool {
                indices.insert(next)
                next += 1
                remainingResults -= 1
            }
            groups.append(ContextMessageGroup(indices: indices))
            index = next
        } else {
            groups.append(ContextMessageGroup(indices: [index]))
            index += 1
        }
    }
    return groups
}