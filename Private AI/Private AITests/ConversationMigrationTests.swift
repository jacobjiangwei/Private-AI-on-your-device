import Foundation
import SwiftData
import Testing
@testable import Private_AI

@MainActor
@Suite("Conversation Migration", .serialized)
struct ConversationMigrationTests {
    @Test("migrates the previous on-disk schema and removes legacy document details")
    func versionOneStore() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let storeURL = root.appending(path: "conversations.store")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let conversationID = UUID()
        let messageID = UUID()
        let privateSentinel = "PRIVATE-LEGACY-DOCUMENT-SENTINEL"

        do {
            let schema = Schema([
                PrivateAISchemaV1.ConversationRecord.self,
                PrivateAISchemaV1.MessageRecord.self
            ])
            let configuration = ModelConfiguration(schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: configuration)
            let context = ModelContext(container)
            let conversation = PrivateAISchemaV1.ConversationRecord(
                id: conversationID,
                title: "Existing conversation",
                modelName: "fixture"
            )
            let message = PrivateAISchemaV1.MessageRecord(
                id: messageID,
                sequence: 1,
                roleRawValue: "user",
                content: "Existing message",
                statusRawValue: "complete",
                conversation: conversation
            )
            let legacyToolMessage = PrivateAISchemaV1.MessageRecord(
                sequence: 2,
                roleRawValue: "tool",
                content: "path=/Users/private/report.pdf query=\(privateSentinel) output=\(privateSentinel)",
                statusRawValue: "complete",
                toolName: "local_resources",
                conversation: conversation
            )
            context.insert(conversation)
            context.insert(message)
            context.insert(legacyToolMessage)
            conversation.messages.append(message)
            conversation.messages.append(legacyToolMessage)
            try context.save()
        }

        let latestSchema = Schema(versionedSchema: PrivateAISchemaV2.self)
        let latestConfiguration = ModelConfiguration(schema: latestSchema, url: storeURL)
        let migrated = try ModelContainer(
            for: latestSchema,
            migrationPlan: PrivateAISchemaMigrationPlan.self,
            configurations: latestConfiguration
        )
        let database = ConversationDatabase(container: migrated)
        try database.sanitizeLegacyLocalResourceMessages()
        let context = ModelContext(migrated)
        let conversations = try context.fetch(FetchDescriptor<ConversationRecord>())
        let messages = try context.fetch(FetchDescriptor<MessageRecord>())
        let migratedUserMessage = messages.first { $0.id == messageID }

        #expect(conversations.first?.id == conversationID)
        #expect(conversations.first?.title == "Existing conversation")
        #expect(migratedUserMessage?.content == "Existing message")
        #expect(migratedUserMessage?.attachments.isEmpty == true)
        #expect(messages.filter { $0.toolName == "local_resources" }.allSatisfy {
            !$0.content.contains(privateSentinel) && !$0.content.contains("/Users/private")
        })
    }
}