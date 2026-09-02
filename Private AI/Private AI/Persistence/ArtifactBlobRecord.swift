import Foundation
import PrivateAITools
import SwiftData

@Model
final class ArtifactBlobRecord {
    @Attribute(.unique) var storageKey: String
    var contentHash: String
    var relativePath: String
    var formatRawValue: String
    var contentTypeIdentifier: String
    var byteCount: Int64
    var createdAt: Date
    @Relationship(deleteRule: .nullify, inverse: \ConversationArtifactRecord.blob)
    var references: [ConversationArtifactRecord]

    var format: LocalDocumentFormat {
        LocalDocumentFormat(rawValue: formatRawValue) ?? .unsupported
    }

    init(
        storageKey: String,
        contentHash: String,
        relativePath: String,
        format: LocalDocumentFormat,
        contentTypeIdentifier: String,
        byteCount: Int64,
        createdAt: Date = .now,
        references: [ConversationArtifactRecord] = []
    ) {
        self.storageKey = storageKey
        self.contentHash = contentHash
        self.relativePath = relativePath
        formatRawValue = format.rawValue
        self.contentTypeIdentifier = contentTypeIdentifier
        self.byteCount = byteCount
        self.createdAt = createdAt
        self.references = references
    }
}