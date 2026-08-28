import Foundation
import XCTest
@testable import PrivateAI

final class ContextPlannerTests: XCTestCase {
    func testPlanPreservesCompleteToolCallAndResultPair() throws {
        let invocation = ToolInvocation(
            id: "search-1",
            name: "web_search",
            arguments: ["query": .string("current Qwen news")]
        )
        let history = [
            ChatMessage(role: .user, content: "Find current Qwen news"),
            ChatMessage(
                role: .assistant,
                content: "",
                responseState: .complete,
                toolCalls: [invocation]
            ),
            ChatMessage(
                role: .tool,
                content: "Qwen released an update.",
                tool: ToolActivity(
                    name: invocation.name,
                    inputSummary: "current Qwen news",
                    status: .success,
                    detail: "Found one result",
                    invocation: invocation
                )
            ),
            ChatMessage(
                role: .assistant,
                content: "Qwen released an update.",
                responseState: .complete
            )
        ]

        let plan = try ContextPlanner.plan(
            history: history,
            prompt: "What was the source result?",
            memories: [],
            thinking: false,
            toolSchemaTokens: 1_000
        )

        let toolCallIndex = try XCTUnwrap(
            plan.messages.firstIndex { message in
                message.toolCalls?.contains { $0.id == invocation.id } == true
            }
        )
        let toolResultIndex = try XCTUnwrap(
            plan.messages.firstIndex { message in
                message.role == .tool && message.content == "Qwen released an update."
            }
        )
        XCTAssertLessThan(toolCallIndex, toolResultIndex)
        XCTAssertEqual(
            plan.messages[toolCallIndex].toolCalls?.first?.function.arguments,
            invocation.arguments
        )
        XCTAssertEqual(plan.receipt.toolPairs, 1)
    }

    func testPlanExcludesFailedAssistantErrorFromFutureContext() throws {
        let history = [
            ChatMessage(role: .user, content: "Question"),
            ChatMessage(
                role: .assistant,
                content: "Request failed.",
                responseState: .failed,
                responseIssue: AssistantResponseIssue(
                    code: .transport,
                    message: "Network connection lost"
                )
            )
        ]

        let plan = try ContextPlanner.plan(
            history: history,
            prompt: "Try something else",
            memories: [],
            thinking: false,
            toolSchemaTokens: 0
        )
        let joined = plan.messages.map(\.content).joined(separator: "\n")

        XCTAssertFalse(joined.contains("Request failed"))
        XCTAssertFalse(joined.contains("Network connection lost"))
    }

    func testPlanCompactsOldTurnsWithoutLosingSeededFact() throws {
        let oldFact = "The project codename is HARBOR-LANTERN."
        let history = [
            ChatMessage(
                role: .user,
                content: oldFact + String(repeating: " old context", count: 1_200)
            ),
            ChatMessage(
                role: .assistant,
                content: String(repeating: "Long old answer. ", count: 1_000),
                responseState: .complete
            ),
            ChatMessage(role: .user, content: "A recent short question"),
            ChatMessage(
                role: .assistant,
                content: "A recent short answer",
                responseState: .complete
            )
        ]

        let plan = try ContextPlanner.plan(
            history: history,
            prompt: "What is the codename?",
            memories: [],
            thinking: false,
            toolSchemaTokens: 0,
            contextWindow: 10_000
        )
        let joined = plan.messages.map(\.content).joined(separator: "\n")

        XCTAssertGreaterThan(plan.receipt.compactedTurns, 0)
        XCTAssertTrue(joined.contains("HARBOR-LANTERN"))
        XCTAssertTrue(joined.contains("A recent short answer"))
        XCTAssertLessThanOrEqual(plan.receipt.estimatedPromptTokens, 10_000)
    }

    func testPlanRejectsMandatoryPromptThatCannotFit() {
        XCTAssertThrowsError(
            try ContextPlanner.plan(
                history: [],
                prompt: String(repeating: "mandatory ", count: 5_000),
                memories: [],
                thinking: false,
                toolSchemaTokens: 0,
                contextWindow: 5_000
            )
        ) { error in
            guard case ContextPlanningError.mandatoryContentTooLarge = error else {
                return XCTFail("Expected mandatoryContentTooLarge, got \(error)")
            }
        }
    }

    func testDynamicConversationRejectsToolGrowthBeyondBudget() {
        let messages = [
            OllamaMessage(role: .system, content: "System"),
            OllamaMessage(
                role: .tool,
                content: String(repeating: "large tool result ", count: 2_000)
            )
        ]

        XCTAssertThrowsError(
            try ContextPlanner.validateDynamicConversation(
                messages,
                outputReserve: 1_000,
                toolSchemaTokens: 0,
                contextWindow: 2_000
            )
        ) { error in
            guard case ContextPlanningError.conversationExceededBudget = error else {
                return XCTFail("Expected conversationExceededBudget, got \(error)")
            }
        }
    }
}
