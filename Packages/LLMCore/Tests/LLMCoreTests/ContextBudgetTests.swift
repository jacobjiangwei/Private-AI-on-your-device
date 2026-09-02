import Foundation
import Testing
@testable import LLMCore

@Suite("Context Budget Trimming")
struct ContextBudgetTests {
    @Test("keeps everything when already within budget")
    func noTrimWhenSmall() {
        let messages = [
            ChatMessage(role: .system, content: "system"),
            ChatMessage(role: .user, content: "hello"),
            ChatMessage(role: .assistant, content: "hi")
        ]
        let result = trimMessagesToBudget(messages, budgetBytes: 10_000)
        #expect(result.didTrim == false)
        #expect(result.messages == messages)
    }

    @Test("never drops the system prompt or current user query")
    func protectsSystemAndCurrentUser() {
        let bigTool = String(repeating: "x", count: 4_000)
        let messages = [
            ChatMessage(role: .system, content: "SYSTEM_PROMPT"),
            ChatMessage(role: .user, content: "FIND_STOCK_PRICE"),
            ChatMessage(role: .assistant, content: "", toolCalls: nil),
            ChatMessage(role: .tool, content: bigTool, toolName: "web"),
            ChatMessage(role: .assistant, content: "", toolCalls: nil),
            ChatMessage(role: .tool, content: bigTool, toolName: "web")
        ]

        let result = trimMessagesToBudget(messages, budgetBytes: 500)

        #expect(result.didTrim == true)
        // The system prompt and the original task must survive trimming.
        #expect(result.messages.first?.role == .system)
        #expect(result.messages.first?.content == "SYSTEM_PROMPT")
        #expect(result.messages.contains { $0.role == .user && $0.content == "FIND_STOCK_PRICE" })
    }

    @Test("keeps the current attachment manifest instead of an old user turn")
    func protectsCurrentAttachmentManifest() {
        let messages = [
            ChatMessage(role: .system, content: "SYSTEM"),
            ChatMessage(role: .user, content: String(repeating: "old", count: 200)),
            ChatMessage(role: .assistant, content: "old answer"),
            ChatMessage(
                role: .user,
                content: "CURRENT privateai.document_attachments IRIS-73"
            )
        ]

        let result = trimMessagesToBudget(messages, budgetBytes: 120)

        #expect(result.messages.contains {
            $0.role == .user && $0.content.contains("privateai.document_attachments")
        })
        #expect(!result.messages.contains { $0.content.hasPrefix("oldold") })
    }

    @Test("prefers the newest messages after the protected ones")
    func keepsNewestAfterProtected() {
        let messages = [
            ChatMessage(role: .system, content: "sys"),
            ChatMessage(role: .user, content: "task"),
            ChatMessage(role: .tool, content: String(repeating: "a", count: 300), toolName: "t"),
            ChatMessage(role: .tool, content: String(repeating: "b", count: 300), toolName: "t"),
            ChatMessage(role: .tool, content: String(repeating: "c", count: 40), toolName: "t")
        ]

        // Budget fits protected (sys+task) plus only the smallest, newest tool result.
        let result = trimMessagesToBudget(messages, budgetBytes: 120)

        #expect(result.didTrim == true)
        #expect(result.messages.contains { $0.content == "sys" })
        #expect(result.messages.contains { $0.content == "task" })
        // Newest small message kept; the two large older ones dropped.
        #expect(result.messages.contains { $0.content.hasPrefix("c") })
        #expect(!result.messages.contains { $0.content.hasPrefix("a") })
        #expect(!result.messages.contains { $0.content.hasPrefix("b") })
    }

    @Test("keeps a tool proposal and all of its results as one group")
    func keepsToolTurnsAtomic() {
        let calls = [
            ToolCall(function: ToolFunctionCall(name: "probe", arguments: [:])),
            ToolCall(function: ToolFunctionCall(name: "probe", arguments: [:]))
        ]
        let messages = [
            ChatMessage(role: .system, content: "sys"),
            ChatMessage(role: .user, content: "current task"),
            ChatMessage(role: .assistant, content: "", toolCalls: calls),
            ChatMessage(role: .tool, content: String(repeating: "a", count: 120), toolName: "probe"),
            ChatMessage(role: .tool, content: String(repeating: "b", count: 120), toolName: "probe"),
            ChatMessage(role: .assistant, content: "latest answer")
        ]

        let result = trimMessagesToBudget(messages, budgetBytes: 120)

        #expect(result.messages.contains { $0.content == "latest answer" })
        #expect(!result.messages.contains { $0.toolCalls != nil })
        #expect(!result.messages.contains { $0.role == .tool })
    }

    @Test("reports when required context alone exceeds the budget")
    func requiredContextTooLarge() {
        let messages = [
            ChatMessage(role: .system, content: String(repeating: "s", count: 100)),
            ChatMessage(role: .user, content: String(repeating: "u", count: 100))
        ]

        let result = trimMessagesToBudget(messages, budgetBytes: 100)

        #expect(result.requiredBytesExceededBudget)
        #expect(result.requiredBytes > 100)
    }
}
