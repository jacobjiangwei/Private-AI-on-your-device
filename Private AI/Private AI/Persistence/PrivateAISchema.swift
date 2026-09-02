import Foundation
import SwiftData

enum PrivateAISchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static let models: [any PersistentModel.Type] = [
        ConversationRecord.self,
        MessageRecord.self
    ]

    @Model
    final class ConversationRecord {
        @Attribute(.unique) var id: UUID
        var title: String
        var modelName: String
        var createdAt: Date
        var updatedAt: Date
        @Relationship(deleteRule: .cascade, inverse: \MessageRecord.conversation)
        var messages: [MessageRecord]

        init(
            id: UUID = UUID(),
            title: String = "New conversation",
            modelName: String = "",
            createdAt: Date = .now,
            updatedAt: Date = .now,
            messages: [MessageRecord] = []
        ) {
            self.id = id
            self.title = title
            self.modelName = modelName
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.messages = messages
        }
    }

    @Model
    final class MessageRecord {
        @Attribute(.unique) var id: UUID
        var sequence: Int64
        var roleRawValue: String
        var content: String
        var statusRawValue: String
        var createdAt: Date
        var errorMessage: String?
        var toolName: String?
        var conversation: ConversationRecord?

        init(
            id: UUID = UUID(),
            sequence: Int64,
            roleRawValue: String,
            content: String,
            statusRawValue: String,
            createdAt: Date = .now,
            errorMessage: String? = nil,
            toolName: String? = nil,
            conversation: ConversationRecord? = nil
        ) {
            self.id = id
            self.sequence = sequence
            self.roleRawValue = roleRawValue
            self.content = content
            self.statusRawValue = statusRawValue
            self.createdAt = createdAt
            self.errorMessage = errorMessage
            self.toolName = toolName
            self.conversation = conversation
        }
    }
}

enum PrivateAISchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static let models: [any PersistentModel.Type] = [
        ConversationRecord.self,
        MessageRecord.self,
        ArtifactBlobRecord.self,
        ConversationArtifactRecord.self
    ]
}

enum PrivateAISchemaMigrationPlan: SchemaMigrationPlan {
    static let schemas: [any VersionedSchema.Type] = [
        PrivateAISchemaV1.self,
        PrivateAISchemaV2.self
    ]
    static let stages: [MigrationStage] = [
        .lightweight(
            fromVersion: PrivateAISchemaV1.self,
            toVersion: PrivateAISchemaV2.self
        )
    ]
}