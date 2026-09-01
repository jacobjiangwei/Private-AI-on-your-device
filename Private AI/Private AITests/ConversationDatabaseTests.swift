import SwiftData
import Testing
@testable import Private_AI

@MainActor
@Suite("Conversation Database")
struct ConversationDatabaseTests {
    @Test("persists ordered messages and derives the initial title")
    func orderedMessages() throws {
        let database = try makeDatabase()
        let conversation = try database.createConversation(modelName: "fixture")

        let user = try database.appendMessage(
            to: conversation,
            role: .user,
            content: "Explain the local model architecture",
            status: .complete
        )
        let assistant = try database.appendMessage(
            to: conversation,
            role: .assistant,
            content: "Architecture result",
            status: .complete
        )

        #expect(user.sequence == 1)
        #expect(assistant.sequence == 2)
        #expect(conversation.title == "Explain the local model architecture")
        #expect(try database.conversations().first?.messages.count == 2)
    }

    @Test("marks unfinished assistant messages as interrupted")
    func interruptionRecovery() throws {
        let database = try makeDatabase()
        let conversation = try database.createConversation(modelName: "fixture")
        let assistant = try database.appendMessage(
            to: conversation,
            role: .assistant,
            content: "Partial response",
            status: .streaming
        )

        try database.markInterruptedMessages()

        #expect(assistant.status == .interrupted)
        #expect(assistant.errorMessage == "The previous response was interrupted.")
    }

    @Test("orders tool events before the final assistant response")
    func orderedToolTranscript() throws {
        let database = try makeDatabase()
        let conversation = try database.createConversation(modelName: "fixture")
        _ = try database.appendMessage(
            to: conversation,
            role: .user,
            content: "Complete the task",
            status: .complete
        )
        let assistant = try database.appendMessage(
            to: conversation,
            role: .assistant,
            content: "",
            status: .streaming
        )
        let firstTool = try database.appendMessage(
            to: conversation,
            role: .tool,
            content: "First tool",
            status: .streaming,
            toolName: "first"
        )
        try database.moveToEnd(assistant)
        let secondTool = try database.appendMessage(
            to: conversation,
            role: .tool,
            content: "Second tool",
            status: .streaming,
            toolName: "second"
        )
        try database.moveToEnd(assistant)

        let ordered = conversation.messages.sorted { $0.sequence < $1.sequence }
        #expect(ordered.map(\.role) == [.user, .tool, .tool, .assistant])
        #expect(ordered[1].id == firstTool.id)
        #expect(ordered[2].id == secondTool.id)
        #expect(ordered[3].id == assistant.id)
    }

    private func makeDatabase() throws -> ConversationDatabase {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: ConversationRecord.self,
            MessageRecord.self,
            configurations: configuration
        )
        return ConversationDatabase(container: container)
    }
}