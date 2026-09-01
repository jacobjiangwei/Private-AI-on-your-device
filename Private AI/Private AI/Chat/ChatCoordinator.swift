import AppKit
import Foundation
import LLMCore
import Observation

@MainActor
@Observable
final class ChatCoordinator {
    private(set) var conversations: [ConversationRecord] = []
    private(set) var selectedConversation: ConversationRecord?
    private(set) var isGenerating = false
    private(set) var activity = ""
    private(set) var transcriptRevision = 0
    private(set) var generationMetrics = GenerationMetrics()
    private(set) var composerFocusRequest = 0
    private(set) var warmupState = "Not started"
    private(set) var warmupElapsedSeconds: Double?
    private(set) var warmupPrefixTokens: Int?
    var draft = ""

    let ollama: OllamaServiceController

    private let database: ConversationDatabase
    private let agent: ChatAgent
    private let log: RuntimeLog
    private var generationTask: Task<Void, Never>?
    private var pendingToolMessageIDs: [UUID] = []
    private var thinkingMessageID: UUID?

    init(dependencies: AppDependencies) {
        database = dependencies.database
        agent = dependencies.agent
        log = dependencies.runtimeLog
        ollama = dependencies.ollama
        reloadConversations()
        Task {
            await ollama.refresh()
            await warmSelectedModel()
        }
    }

    var messages: [MessageRecord] {
        selectedConversation?.messages.sorted { $0.sequence < $1.sequence } ?? []
    }

    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !ollama.selectedModel.isEmpty
            && ollama.state.isReady
            && !isGenerating
    }

    func newConversation() {
        do {
            selectedConversation = try database.createConversation(modelName: ollama.selectedModel)
            reloadConversations(preservingSelection: true)
            composerFocusRequest += 1
        } catch {
            activity = error.localizedDescription
        }
    }

    func selectConversation(id: UUID) {
        selectedConversation = conversations.first { $0.id == id }
        composerFocusRequest += 1
    }

    func deleteConversation(_ conversation: ConversationRecord) {
        guard !isGenerating || selectedConversation?.id != conversation.id else { return }
        do {
            try database.delete(conversation)
            if selectedConversation?.id == conversation.id {
                selectedConversation = nil
            }
            reloadConversations()
        } catch {
            activity = error.localizedDescription
        }
    }

    func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, canSend else { return }

        do {
            let conversation = try selectedConversation
                ?? database.createConversation(modelName: ollama.selectedModel)
            selectedConversation = conversation
            conversation.modelName = ollama.selectedModel
            let history = modelHistory(for: conversation)
            try database.appendMessage(
                to: conversation,
                role: .user,
                content: prompt,
                status: .complete
            )
            let assistant = try database.appendMessage(
                to: conversation,
                role: .assistant,
                content: "",
                status: .streaming
            )
            draft = ""
            isGenerating = true
            pendingToolMessageIDs = []
            thinkingMessageID = nil
            generationMetrics.start()
            activity = "Thinking"
            Task {
                await log.record("chat.generation.started", fields: [
                    "conversation_id": conversation.id.uuidString,
                    "model": conversation.modelName
                ])
            }
            reloadConversations(preservingSelection: true)
            let assistantID = assistant.id
            let conversationID = conversation.id
            let runID = UUID()

            generationTask = Task { [weak self] in
                guard let self else { return }
                await log.record(
                    "run.started",
                    category: "agent",
                    runID: runID,
                    conversationID: conversationID,
                    data: [
                        "history_message_count": history.count,
                        "model": conversation.modelName,
                        "prompt": prompt,
                        "system_prompt_version": LLMCoreSystemPrompt.version
                    ]
                )
                do {
                    let result = try await agent.respond(
                        prompt: prompt,
                        history: history,
                        model: conversation.modelName,
                        runID: runID,
                        conversationID: conversationID
                    ) { event in
                        await self.consume(
                            event,
                            assistantID: assistantID,
                            conversationID: conversationID,
                            runID: runID
                        )
                    }
                    try database.update(assistant, content: result.text, status: .complete)
                    generationMetrics.finish(performance: result.performance)
                    await log.record("chat.generation.finished", fields: [
                        "conversation_id": conversationID.uuidString,
                        "tokens_per_second": String(generationMetrics.finalTokensPerSecond ?? 0),
                        "ttft_seconds": String(generationMetrics.ttftSeconds ?? 0)
                    ])
                    await log.record(
                        "run.finished",
                        category: "agent",
                        runID: runID,
                        conversationID: conversationID,
                        data: [
                            "answer": result.text,
                            "model_request_count": result.performance.modelRequestCount,
                            "output_token_count": result.performance.modelUsage.reduce(0) {
                                $0 + ($1.outputTokenCount ?? 0)
                            },
                            "time_to_first_event_seconds": jsonNumber(result.performance.timeToFirstEventSeconds),
                            "time_to_first_text_seconds": jsonNumber(result.performance.timeToFirstTextSeconds),
                            "tokens_per_second": jsonNumber(generationMetrics.finalTokensPerSecond),
                            "tool_call_count": result.performance.toolCallCount,
                            "total_seconds": result.performance.totalSeconds
                        ]
                    )
                    transcriptRevision += 1
                    activity = ""
                } catch is CancellationError {
                    generationMetrics.stop()
                    try? database.update(
                        assistant,
                        status: .interrupted,
                        errorMessage: "Generation stopped."
                    )
                    transcriptRevision += 1
                    activity = "Stopped"
                    await log.record("chat.generation.cancelled", fields: [
                        "conversation_id": conversationID.uuidString
                    ])
                    await log.record(
                        "run.cancelled",
                        level: "warning",
                        category: "agent",
                        runID: runID,
                        conversationID: conversationID
                    )
                } catch {
                    generationMetrics.stop()
                    try? database.update(
                        assistant,
                        status: .failed,
                        errorMessage: error.localizedDescription
                    )
                    transcriptRevision += 1
                    activity = error.localizedDescription
                    await log.record("chat.generation.failed", fields: [
                        "conversation_id": conversationID.uuidString,
                        "error": String(describing: error)
                    ])
                    await log.record(
                        "run.failed",
                        level: "error",
                        category: "agent",
                        runID: runID,
                        conversationID: conversationID,
                        data: ["error": String(describing: error)]
                    )
                }
                isGenerating = false
                generationTask = nil
                reloadConversations(preservingSelection: true)
            }
        } catch {
            activity = error.localizedDescription
        }
    }

    func stop() {
        generationTask?.cancel()
    }

    func selectModel(_ model: String) {
        ollama.selectedModel = model
        warmupState = "Not started"
        warmupElapsedSeconds = nil
        warmupPrefixTokens = nil
        Task { await warmSelectedModel() }
    }

    func copyMessage(id: UUID) {
        guard let message = messages.first(where: { $0.id == id }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
    }

    private func consume(
        _ event: AgentEvent,
        assistantID: UUID,
        conversationID: UUID,
        runID: UUID
    ) async {
        guard let conversation = conversations.first(where: { $0.id == conversationID }),
              let assistant = conversation.messages.first(where: { $0.id == assistantID })
        else {
            return
        }
        switch event {
        case .modelRequestStarted(let round):
            await log.record(
                "model.request.started",
                category: "model",
                runID: runID,
                conversationID: conversationID,
                round: round,
                data: ["model": ollama.selectedModel]
            )
        case .modelRequestFinished(let round, let usage):
            await log.record(
                "model.request.finished",
                category: "model",
                runID: runID,
                conversationID: conversationID,
                round: round,
                data: usageData(usage)
            )
        case .thinking(let delta):
            activity = "Thinking"
            let thinkingMessage: MessageRecord?
            if let thinkingMessageID {
                thinkingMessage = conversation.messages.first { $0.id == thinkingMessageID }
            } else {
                thinkingMessage = try? database.appendMessage(
                    to: conversation,
                    role: .thinking,
                    content: "",
                    status: .streaming
                )
                thinkingMessageID = thinkingMessage?.id
                try? database.moveToEnd(assistant)
            }
            if let thinkingMessage {
                try? database.update(
                    thinkingMessage,
                    content: thinkingMessage.content + delta
                )
                transcriptRevision += 1
            }
            await log.record(
                "model.thinking.delta",
                category: "model",
                runID: runID,
                conversationID: conversationID,
                data: ["characters": delta.count, "text": delta]
            )
        case .text(let delta):
            completeThinkingMessage(in: conversation)
            generationMetrics.recordText(delta)
            _ = try? database.update(assistant, content: assistant.content + delta)
            transcriptRevision += 1
            activity = "Responding"
            await log.record(
                assistant.content == delta ? "model.text.first" : "model.text.delta",
                category: "model",
                runID: runID,
                conversationID: conversationID,
                data: [
                    "characters": delta.count,
                    "text": delta,
                    "total_characters": assistant.content.count
                ]
            )
        case .toolCallsProposed(let round, let calls):
            await log.record(
                "model.tool_calls.proposed",
                category: "model",
                runID: runID,
                conversationID: conversationID,
                round: round,
                data: ["calls": calls.map(toolCallData)]
            )
        case .toolStarted(let name, let arguments):
            completeThinkingMessage(in: conversation)
            activity = "Using \(name)"
            if let toolMessage = try? database.appendMessage(
                to: conversation,
                role: .tool,
                content: toolStartedContent(name: name, arguments: arguments),
                status: .streaming,
                toolName: name
            ) {
                pendingToolMessageIDs.append(toolMessage.id)
                try? database.moveToEnd(assistant)
                transcriptRevision += 1
            }
            await log.record("tool.started", fields: [
                "action": arguments["action"]?.stringValue ?? "",
                "conversation_id": conversationID.uuidString,
                "tool": name
            ])
            await log.record(
                "tool.execution.started",
                category: "tool",
                runID: runID,
                conversationID: conversationID,
                data: [
                    "arguments": jsonObject(.object(arguments)),
                    "name": name
                ]
            )
        case .toolFinished(let execution):
            if let toolMessageID = pendingToolMessageIDs.first {
                pendingToolMessageIDs.removeFirst()
                if let toolMessage = conversation.messages.first(where: { $0.id == toolMessageID }) {
                    try? database.update(
                        toolMessage,
                        content: toolFinishedContent(execution),
                        status: execution.succeeded ? .complete : .failed,
                        errorMessage: execution.succeeded ? nil : "Tool execution failed."
                    )
                }
            }
            transcriptRevision += 1
            activity = execution.succeeded ? "Reading tool result" : "Tool failed"
            await log.record("tool.finished", fields: [
                "conversation_id": conversationID.uuidString,
                "succeeded": String(execution.succeeded),
                "tool": execution.name
            ])
            await log.record(
                "tool.execution.finished",
                level: execution.succeeded ? "info" : "error",
                category: "tool",
                runID: runID,
                conversationID: conversationID,
                data: [
                    "arguments": jsonObject(.object(execution.arguments)),
                    "name": execution.name,
                    "output": execution.content,
                    "succeeded": execution.succeeded
                ]
            )
        case .contextTrimmed(let dropped, let before, let after):
            await log.record(
                "context.trimmed",
                level: "warning",
                category: "model",
                runID: runID,
                conversationID: conversationID,
                data: [
                    "dropped_messages": dropped,
                    "approx_bytes_before": before,
                    "approx_bytes_after": after
                ]
            )
        }
    }

    private func completeThinkingMessage(in conversation: ConversationRecord) {
        guard let thinkingMessageID,
              let thinkingMessage = conversation.messages.first(where: { $0.id == thinkingMessageID }),
              thinkingMessage.status == .streaming
        else {
            return
        }
        try? database.update(thinkingMessage, status: .complete)
        transcriptRevision += 1
    }

    private func usageData(_ usage: ModelUsage) -> [String: Any] {
        [
            "load_duration_nanoseconds": jsonNumber(usage.loadDurationNanoseconds),
            "output_duration_nanoseconds": jsonNumber(usage.outputDurationNanoseconds),
            "output_token_count": jsonNumber(usage.outputTokenCount),
            "prompt_duration_nanoseconds": jsonNumber(usage.promptDurationNanoseconds),
            "prompt_token_count": jsonNumber(usage.promptTokenCount),
            "total_duration_nanoseconds": jsonNumber(usage.totalDurationNanoseconds)
        ]
    }

    private func jsonNumber<T: BinaryInteger>(_ value: T?) -> Any {
        value.map { NSNumber(value: Int64($0)) } ?? NSNull()
    }

    private func jsonNumber(_ value: Double?) -> Any {
        value.map(NSNumber.init(value:)) ?? NSNull()
    }

    private func toolCallData(_ call: ToolCall) -> [String: Any] {
        [
            "arguments": jsonObject(.object(call.function.arguments)),
            "name": call.function.name,
            "type": call.type
        ]
    }

    private func jsonObject(_ value: JSONValue) -> Any {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return [:]
        }
        return object
    }

    private func toolStartedContent(
        name: String,
        arguments: [String: JSONValue]
    ) -> String {
        let input = encodedJSON(.object(arguments))
        return """
        **Tool:** `\(name)`

        **Status:** Running

        **Input**

        ```json
        \(input)
        ```
        """
    }

    private func toolFinishedContent(_ execution: ToolExecution) -> String {
        """
        **Tool:** `\(execution.name)`

        **Status:** \(execution.succeeded ? "Succeeded" : "Failed")

        **Input**

        ```json
        \(encodedJSON(.object(execution.arguments)))
        ```

        **Output**

        ```json
        \(execution.content)
        ```
        """
    }

    private func encodedJSON(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data),
              let prettyData = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys]
              )
        else {
            return "{}"
        }
        return String(decoding: prettyData, as: UTF8.self)
    }

    private func warmSelectedModel() async {
        let model = ollama.selectedModel
        guard ollama.state.isReady, !model.isEmpty else { return }
        warmupState = "Preparing model and stable prompt prefix"
        do {
            let metrics = try await agent.warmUp(model: model)
            guard ollama.selectedModel == model else { return }
            warmupElapsedSeconds = metrics.elapsedSeconds
            warmupPrefixTokens = metrics.prefixPromptTokenCount
            warmupState = "Ready"
        } catch {
            guard ollama.selectedModel == model else { return }
            warmupState = "Failed: \(error.localizedDescription)"
            await log.record("chat.warmup.unavailable", fields: [
                "error": String(describing: error),
                "model": model
            ])
        }
    }

    private func modelHistory(for conversation: ConversationRecord) -> [ChatMessage] {
        conversation.messages
            .sorted { $0.sequence < $1.sequence }
            .compactMap { message in
                guard message.status == .complete else { return nil }
                switch message.role {
                case .user:
                    return ChatMessage(role: .user, content: message.content)
                case .assistant:
                    return ChatMessage(role: .assistant, content: message.content)
                case .thinking, .tool:
                    return nil
                }
            }
    }

    private func reloadConversations(preservingSelection: Bool = false) {
        let selectedID = preservingSelection ? selectedConversation?.id : nil
        do {
            conversations = try database.conversations()
            if let selectedID {
                selectedConversation = conversations.first { $0.id == selectedID }
            } else if selectedConversation == nil {
                selectedConversation = conversations.first
            }
        } catch {
            activity = error.localizedDescription
        }
    }
}