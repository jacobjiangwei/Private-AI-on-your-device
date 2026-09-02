import Foundation
import SwiftData

@Model
final class ConversationArtifactRecord {
    @Attribute(.unique) var id: UUID
    var displayName: String
    var sortOrder: Int
    var createdAt: Date
    var message: MessageRecord?
    var blob: ArtifactBlobRecord?

    init(
        id: UUID = UUID(),
        displayName: String,
        sortOrder: Int,
        createdAt: Date = .now,
        message: MessageRecord? = nil,
        blob: ArtifactBlobRecord? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.message = message
        self.blob = blob
    }
}