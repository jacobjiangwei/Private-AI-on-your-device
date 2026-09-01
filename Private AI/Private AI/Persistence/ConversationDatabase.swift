import Foundation
import SwiftData

@MainActor
final class ConversationDatabase {
    private let context: ModelContext

    init(container: ModelContainer) {
        self.context = ModelContext(container)
        self.context.autosaveEnabled = true
    }

    func conversations() throws -> [ConversationRecord] {
        var descriptor = FetchDescriptor<ConversationRecord>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 200
        return try context.fetch(descriptor)
    }

    func createConversation(modelName: String) throws -> ConversationRecord {
        let conversation = ConversationRecord(modelName: modelName)
        context.insert(conversation)
        try context.save()
        return conversation
    }

    @discardableResult
    func appendMessage(
        to conversation: ConversationRecord,
        role: PersistedMessageRole,
        content: String,
        status: PersistedMessageStatus,
        toolName: String? = nil
    ) throws -> MessageRecord {
        let sequence = (conversation.messages.map(\.sequence).max() ?? 0) + 1
        let message = MessageRecord(
            sequence: sequence,
            role: role,
            content: content,
            status: status,
            toolName: toolName,
            conversation: conversation
        )
        context.insert(message)
        conversation.messages.append(message)
        conversation.updatedAt = .now
        if role == .user, conversation.title == "New conversation" {
            conversation.title = String(content.prefix(48))
        }
        try context.save()
        return message
    }

    func update(
        _ message: MessageRecord,
        content: String? = nil,
        status: PersistedMessageStatus? = nil,
        errorMessage: String? = nil
    ) throws {
        if let content {
            message.content = content
        }
        if let status {
            message.status = status
        }
        message.errorMessage = errorMessage
        message.conversation?.updatedAt = .now
        try context.save()
    }

    func moveToEnd(_ message: MessageRecord) throws {
        guard let conversation = message.conversation else { return }
        message.sequence = (conversation.messages.map(\.sequence).max() ?? 0) + 1
        conversation.updatedAt = .now
        try context.save()
    }

    func delete(_ conversation: ConversationRecord) throws {
        context.delete(conversation)
        try context.save()
    }

    func markInterruptedMessages() throws {
        let descriptor = FetchDescriptor<MessageRecord>(
            predicate: #Predicate { $0.statusRawValue == "streaming" }
        )
        for message in try context.fetch(descriptor) {
            message.status = .interrupted
            message.errorMessage = "The previous response was interrupted."
        }
        try context.save()
    }
}