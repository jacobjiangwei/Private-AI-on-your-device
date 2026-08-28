import Foundation

public enum ContextPlanningError: LocalizedError, Sendable {
    case mandatoryContentTooLarge(estimatedTokens: Int, availableTokens: Int)
    case conversationExceededBudget(estimatedTokens: Int, availableTokens: Int)

    public var errorDescription: String? {
        switch self {
        case .mandatoryContentTooLarge(let estimated, let available):
            String(localized: "The current request needs about \(estimated) tokens, but only \(available) input tokens are available.")
        case .conversationExceededBudget(let estimated, let available):
            String(localized: "The conversation grew to about \(estimated) tokens, beyond the \(available)-token input budget.")
        }
    }
}

public struct ContextPlan: Sendable {
    public let messages: [OllamaMessage]
    public let receipt: ContextReceipt

    public init(messages: [OllamaMessage], receipt: ContextReceipt) {
        self.messages = messages
        self.receipt = receipt
    }
}

public enum ContextPlanner {
    public static let defaultContextWindow = 32_768
    public static let fastOutputReserve = 4_096
    public static let thinkingOutputReserve = 8_192
    public static let safetyReserve = 512

    public static func plan(
        history: [ChatMessage],
        prompt: String,
        memories: [MemoryRecord],
        thinking: Bool,
        toolSchemaTokens: Int,
        attachmentContext: AttachmentContext? = nil,
        contextWindow: Int = defaultContextWindow
    ) throws -> ContextPlan {
        let outputReserve = thinking ? thinkingOutputReserve : fastOutputReserve
        let available = max(
            contextWindow - outputReserve - safetyReserve - max(toolSchemaTokens, 0),
            0
        )
        let system = LocalChatPrompt.systemMessage(memories: memories)
        let continuation: OllamaMessage? = history.contains { $0.role == .user }
            ? LocalChatPrompt.sessionContinuationMessage(
                recentUserMessages: history
                    .filter { $0.role == .user }
                    .suffix(3)
                    .map(\.content)
            )
            : nil
        var currentContent = prompt
        if let attachmentText = attachmentContext?.text, !attachmentText.isEmpty {
            currentContent += "\n\n" + attachmentText
        }
        let images = attachmentContext?.images ?? []
        let current = OllamaMessage(
            role: .user,
            content: currentContent,
            images: images.isEmpty ? nil : images
        )
        let mandatory = [system] + (continuation.map { [$0] } ?? []) + [current]
        let mandatoryTokens = estimateTokens(mandatory)
        guard mandatoryTokens <= available else {
            throw ContextPlanningError.mandatoryContentTooLarge(
                estimatedTokens: mandatoryTokens,
                availableTokens: available
            )
        }

        let turns = makeTurns(history)
        var selected: [(index: Int, messages: [OllamaMessage], compacted: Bool)] = []
        var used = mandatoryTokens
        var fullTurns = 0
        var compactedTurns = 0
        var omittedTurns = 0
        var toolPairs = 0

        for indexedTurn in turns.enumerated().reversed() {
            let full = ollamaMessages(for: indexedTurn.element)
            guard !full.isEmpty else { continue }
            let fullTokens = estimateTokens(full)
            if used + fullTokens <= available {
                selected.append((indexedTurn.offset, full, false))
                used += fullTokens
                fullTurns += 1
                toolPairs += indexedTurn.element.filter {
                    $0.role == .tool && $0.tool?.invocation != nil
                }.count
                continue
            }

            let compacted = compactedMessage(for: indexedTurn.element)
            let compactedTokens = estimateTokens([compacted])
            if used + compactedTokens <= available {
                selected.append((indexedTurn.offset, [compacted], true))
                used += compactedTokens
                compactedTurns += 1
            } else {
                omittedTurns += 1
            }
        }

        selected.sort { $0.index < $1.index }
        var messages = [system]
        messages.append(contentsOf: selected.flatMap(\.messages))
        if let continuation { messages.append(continuation) }
        messages.append(current)
        let estimatedPromptTokens = estimateTokens(messages)
            + max(toolSchemaTokens, 0)
            + safetyReserve
        return ContextPlan(
            messages: messages,
            receipt: ContextReceipt(
                contextWindow: contextWindow,
                outputReserve: outputReserve,
                estimatedPromptTokens: estimatedPromptTokens,
                fullTurns: fullTurns,
                compactedTurns: compactedTurns,
                omittedTurns: omittedTurns,
                memoryRecords: memories.count,
                toolPairs: toolPairs,
                attachmentTokens: attachmentContext?.estimatedTokens ?? 0,
                attachmentChunks: attachmentContext?.chunkCount ?? 0,
                documentProfiles: attachmentContext?.profileCount ?? 0,
                visionImages: images.count
            )
        )
    }

    public static func validateDynamicConversation(
        _ messages: [OllamaMessage],
        outputReserve: Int,
        toolSchemaTokens: Int,
        contextWindow: Int = defaultContextWindow
    ) throws {
        let available = max(
            contextWindow - outputReserve - safetyReserve - max(toolSchemaTokens, 0),
            0
        )
        let estimate = estimateTokens(messages)
        guard estimate <= available else {
            throw ContextPlanningError.conversationExceededBudget(
                estimatedTokens: estimate,
                availableTokens: available
            )
        }
    }

    public static func estimateTokens(_ messages: [OllamaMessage]) -> Int {
        messages.reduce(0) { result, message in
            let withoutImages = OllamaMessage(
                role: message.role,
                content: message.content,
                toolCalls: message.toolCalls
            )
            let encodedBytes = (try? JSONEncoder().encode(withoutImages).count)
                ?? message.content.utf8.count
            let imageTokens = (message.images?.count ?? 0) * 2_048
            return result + Int(ceil(Double(encodedBytes) / 3.0)) + 8 + imageTokens
        }
    }

    private static func makeTurns(_ history: [ChatMessage]) -> [[ChatMessage]] {
        var turns: [[ChatMessage]] = []
        var current: [ChatMessage] = []
        for message in history {
            if message.role == .user, !current.isEmpty {
                turns.append(current)
                current = []
            }
            current.append(message)
        }
        if !current.isEmpty { turns.append(current) }
        return turns
    }

    private static func ollamaMessages(for turn: [ChatMessage]) -> [OllamaMessage] {
        var messages: [OllamaMessage] = []
        var emittedCallIDs = Set<String>()
        for message in turn {
            switch message.role {
            case .user:
                guard !message.content.isEmpty else { continue }
                messages.append(OllamaMessage(role: .user, content: message.content))
            case .assistant:
                guard message.responseState != .failed,
                      message.responseState != .stopped,
                      message.responseState != .streaming
                else { continue }
                let calls = message.toolCalls?.map {
                    OllamaToolCall(id: $0.id, name: $0.name, arguments: $0.arguments)
                }
                emittedCallIDs.formUnion(message.toolCalls?.map(\.id) ?? [])
                guard !message.content.isEmpty || calls?.isEmpty == false else { continue }
                messages.append(
                    OllamaMessage(
                        role: .assistant,
                        content: message.content,
                        toolCalls: calls?.isEmpty == false ? calls : nil
                    )
                )
            case .tool:
                guard message.tool?.status != .running,
                      let invocation = message.tool?.invocation
                else { continue }
                if !emittedCallIDs.contains(invocation.id) {
                    messages.append(
                        OllamaMessage(
                            role: .assistant,
                            content: "",
                            toolCalls: [
                                OllamaToolCall(
                                    id: invocation.id,
                                    name: invocation.name,
                                    arguments: invocation.arguments
                                )
                            ]
                        )
                    )
                    emittedCallIDs.insert(invocation.id)
                }
                messages.append(OllamaMessage(role: .tool, content: message.content))
            case .system:
                continue
            }
        }
        return messages
    }

    private static func compactedMessage(for turn: [ChatMessage]) -> OllamaMessage {
        let user = turn.first(where: { $0.role == .user })?.content ?? ""
        let assistant = turn.last(where: {
            $0.role == .assistant && $0.responseState != .failed
                && $0.responseState != .stopped && !$0.content.isEmpty
        })?.content ?? ""
        let tools = turn.compactMap { message -> String? in
            guard message.role == .tool, let tool = message.tool else { return nil }
            let sourceNames = tool.sources.prefix(3).map(\.title).joined(separator: ", ")
            let suffix = sourceNames.isEmpty ? "" : " Sources: \(sourceNames)."
            return "\(tool.name): \(String(tool.detail.prefix(500)))\(suffix)"
        }
        var summary = "[Compacted prior turn]\nUser: \(bounded(user, limit: 1_200))"
        if !tools.isEmpty {
            summary += "\nTools: \(tools.joined(separator: " | "))"
        }
        if !assistant.isEmpty {
            summary += "\nAssistant: \(bounded(assistant, limit: 1_800))"
        }
        return OllamaMessage(role: .system, content: summary)
    }

    private static func bounded(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        let headCount = limit * 2 / 3
        let tailCount = limit - headCount
        return "\(value.prefix(headCount)) … \(value.suffix(tailCount))"
    }
}
