import AppKit
import CryptoKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public enum AttachmentStoreError: LocalizedError, Sendable {
    case unsupportedType
    case fileTooLarge(maximumBytes: Int64)
    case corruptImage
    case corruptPDF
    case encryptedPDF
    case missingSource
    case sourceIntegrityMismatch
    case noExtractableText
    case unsupportedTextEncoding

    public var errorDescription: String? {
        switch self {
        case .unsupportedType:
            String(localized: "PrivateAI supports PDF, static images, text, common source-code files, RTF, HTML, Word, and OpenDocument attachments.")
        case .fileTooLarge(let maximumBytes):
            String(localized: "The attachment exceeds the \(ByteCountFormatter.string(fromByteCount: maximumBytes, countStyle: .file)) limit.")
        case .corruptImage:
            String(localized: "The image could not be decoded.")
        case .corruptPDF:
            String(localized: "The PDF could not be opened.")
        case .encryptedPDF:
            String(localized: "Encrypted PDFs are not supported.")
        case .missingSource:
            String(localized: "The local attachment data is missing.")
        case .sourceIntegrityMismatch:
            String(localized: "The stored document no longer matches the file that was originally imported.")
        case .noExtractableText:
            String(localized: "This PDF has no usable embedded text. Scanned and complex PDFs are not supported in this version.")
        case .unsupportedTextEncoding:
            String(localized: "This text file is not valid UTF-8.")
        }
    }
}

public struct AttachmentContext: Sendable {
    public let text: String
    public let images: [String]
    public let chunkCount: Int
    public let profileCount: Int
    public let estimatedTokens: Int

    public init(
        text: String,
        images: [String],
        chunkCount: Int,
        profileCount: Int = 0,
        estimatedTokens: Int
    ) {
        self.text = text
        self.images = images
        self.chunkCount = chunkCount
        self.profileCount = profileCount
        self.estimatedTokens = estimatedTokens
    }
}

public struct PDFTextChunk: Codable, Sendable {
    public let page: Int
    public let text: String

    public init(page: Int, text: String) {
        self.page = page
        self.text = text
    }
}

public protocol AdvancedPDFParsing: Sendable {
    var parserID: String { get }
    var parserVersion: String { get }
    func parsePDF(at url: URL) async throws -> [PDFTextChunk]
}

public actor AttachmentStore {
    public static let maximumFileBytes: Int64 = 250 * 1_024 * 1_024
    public static let maximumImageBytes: Int64 = 25 * 1_024 * 1_024
    public static let maximumTextBytes: Int64 = 50 * 1_024 * 1_024
    public static let maximumVisionImages = 4
    public static let maximumVisionPayloadBytes = 12 * 1_024 * 1_024
    public static let maximumAttachmentsPerChat = 8
    private static let pendingImportMarker = ".pending-import"
    private static let pendingDeletesDirectoryName = "PendingDeletes"
    private static let deletedDocumentsDirectoryName = "DeletedDocuments"

    private let directory: URL
    private let fileManager: FileManager
    private let advancedPDFParser: (any AdvancedPDFParsing)?
    private let libraryStore: DocumentLibraryStore
    private var validatedBlobs: [UUID: BlobFingerprint] = [:]

    public init(
        directory: URL? = nil,
        fileManager: FileManager = .default,
        advancedPDFParser: (any AdvancedPDFParsing)? = nil,
        libraryStore: DocumentLibraryStore? = nil
    ) throws {
        self.fileManager = fileManager
        self.directory = try directory
            ?? LocalChatPaths.applicationSupportRoot(fileManager: fileManager)
                .appendingPathComponent("Attachments", isDirectory: true)
        self.advancedPDFParser = advancedPDFParser
        self.libraryStore = try libraryStore ?? DocumentLibraryStore(
            databaseURL: self.directory.deletingLastPathComponent()
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("documents.sqlite3")
        )
        try fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: self.directory.appendingPathComponent(
                Self.pendingDeletesDirectoryName,
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: self.directory.appendingPathComponent(
                Self.deletedDocumentsDirectoryName,
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )
    }

    public func importFile(at externalURL: URL) async throws -> AttachmentReference {
        try Task.checkCancellation()
        let accessed = externalURL.startAccessingSecurityScopedResource()
        var scopeIsActive = accessed
        defer {
            if scopeIsActive { externalURL.stopAccessingSecurityScopedResource() }
        }

        let values = try externalURL.resourceValues(forKeys: [
            .contentTypeKey,
            .fileSizeKey,
            .nameKey
        ])
        let contentType = values.contentType
            ?? UTType(filenameExtension: externalURL.pathExtension)
        let kind: AttachmentKind
        if contentType?.conforms(to: .pdf) == true {
            kind = .pdf
        } else if contentType?.conforms(to: .image) == true {
            kind = .image
        } else if contentType?.conforms(to: .text) == true
            || Self.textFileExtensions.contains(externalURL.pathExtension.lowercased()) {
            kind = .text
        } else {
            throw AttachmentStoreError.unsupportedType
        }
        let reportedByteCount = Int64(values.fileSize ?? 0)
        let maximum: Int64
        switch kind {
        case .image: maximum = Self.maximumImageBytes
        case .pdf: maximum = Self.maximumFileBytes
        case .text: maximum = Self.maximumTextBytes
        }
        guard reportedByteCount <= maximum else {
            throw AttachmentStoreError.fileTooLarge(maximumBytes: maximum)
        }

        let id = UUID()
        let attachmentDirectory = directory.appendingPathComponent(
            id.uuidString,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: attachmentDirectory,
            withIntermediateDirectories: true
        )
        do {
            try Data().write(
                to: attachmentDirectory.appendingPathComponent(
                    Self.pendingImportMarker
                ),
                options: .atomic
            )
        } catch {
            try? fileManager.removeItem(at: attachmentDirectory)
            throw error
        }
        let source = attachmentDirectory.appendingPathComponent(
            "source.\(externalURL.pathExtension.isEmpty ? defaultExtension(for: kind) : externalURL.pathExtension)"
        )
        do {
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(
                readingItemAt: externalURL,
                options: .withoutChanges,
                error: &coordinationError
            ) { coordinatedURL in
                do {
                    try fileManager.copyItem(at: coordinatedURL, to: source)
                } catch {
                    copyError = error
                }
            }
            if let coordinationError { throw coordinationError }
            if let copyError { throw copyError }
        } catch {
            try? fileManager.removeItem(at: attachmentDirectory)
            throw error
        }
        if scopeIsActive {
            externalURL.stopAccessingSecurityScopedResource()
            scopeIsActive = false
        }

        do {
            let copiedValues = try source.resourceValues(forKeys: [.fileSizeKey])
            let byteCount = Int64(copiedValues.fileSize ?? 0)
            guard byteCount <= maximum else {
                throw AttachmentStoreError.fileTooLarge(maximumBytes: maximum)
            }
            let digest = try sha256(of: source)
            if let existing = try await libraryStore.document(withSHA256: digest) {
                let canonicalSource = try canonicalBlobURL(for: existing)
                let canonicalDigest = try? sha256(of: canonicalSource)
                if canonicalDigest != digest {
                    try repairCanonicalBlob(
                        from: source,
                        to: canonicalSource,
                        expectedSHA256: digest
                    )
                }
                validatedBlobs[existing.id] = try blobFingerprint(canonicalSource)
                try? fileManager.removeItem(at: attachmentDirectory)
                let usageReference = reference(
                    existing.reference,
                    displayName: values.name ?? externalURL.lastPathComponent
                )
                _ = try await libraryStore.insertOrFetch(
                    usageReference,
                    blobRelativePath: existing.blobRelativePath,
                    chunks: []
                )
                return usageReference
            }

            let importedReference: AttachmentReference
            switch kind {
            case .image:
                importedReference = try importImage(
                    id: id,
                    source: source,
                    displayName: values.name ?? externalURL.lastPathComponent,
                    contentType: contentType,
                    byteCount: byteCount,
                    digest: digest
                )
            case .pdf:
                importedReference = try await importPDF(
                    id: id,
                    source: source,
                    displayName: values.name ?? externalURL.lastPathComponent,
                    contentType: contentType,
                    byteCount: byteCount,
                    digest: digest
                )
            case .text:
                importedReference = try importText(
                    id: id,
                    source: source,
                    displayName: values.name ?? externalURL.lastPathComponent,
                    contentType: contentType,
                    byteCount: byteCount,
                    digest: digest
                )
            }
            let chunks = importedReference.kind == .image
                ? []
                : try loadLegacyChunks(for: importedReference.id)
            let fingerprint = try blobFingerprint(source)
            let stored = try await libraryStore.insertOrFetch(
                importedReference,
                blobRelativePath: relativeSourcePath(for: importedReference.id),
                chunks: chunks
            )
            if stored.reference.id != importedReference.id {
                let canonicalSource = try canonicalBlobURL(for: stored)
                if (try? sha256(of: canonicalSource)) != digest {
                    try repairCanonicalBlob(
                        from: source,
                        to: canonicalSource,
                        expectedSHA256: digest
                    )
                }
                validatedBlobs[stored.id] = try blobFingerprint(canonicalSource)
                try? fileManager.removeItem(at: attachmentDirectory)
                return reference(
                    stored.reference,
                    displayName: importedReference.displayName
                )
            }
            validatedBlobs[importedReference.id] = fingerprint
            try? fileManager.removeItem(
                at: attachmentDirectory.appendingPathComponent(
                    Self.pendingImportMarker
                )
            )
            return importedReference
        } catch {
            try? fileManager.removeItem(at: attachmentDirectory)
            throw error
        }
    }

    public func context(
        for attachments: [AttachmentReference],
        query: String,
        profiles: [UUID: DocumentProfile] = [:],
        maximumTextCharacters: Int = 12_000
    ) async throws -> AttachmentContext {
        var textSections: [String] = []
        var images: [String] = []
        var chunkCount = 0
        var visionBytes = 0

        let readyAttachments = attachments.filter { $0.state == .ready }
        let profileText = renderProfiles(
            profiles,
            attachments: readyAttachments,
            maximumCharacters: maximumTextCharacters / 4
        )
        var remainingCharacters = max(
            maximumTextCharacters - profileText.count,
            0
        )
        let textAttachments = readyAttachments.filter {
            $0.kind == .pdf || $0.kind == .text
        }
        for (offset, attachment) in textAttachments.enumerated() {
            try Task.checkCancellation()
            let canonical = try await canonicalReference(for: attachment)
            let remainingAttachmentCount = textAttachments.count - offset
            let fairShare = remainingAttachmentCount > 0
                ? remainingCharacters / remainingAttachmentCount
                : 0
            let chunks = try await storedChunks(for: canonical)
            let selected = selectRelevant(
                chunks,
                query: query,
                maximumCharacters: fairShare
            )
            let rendered = renderSelectedChunks(
                selected,
                attachment: attachment,
                maximumCharacters: fairShare
            )
            if !rendered.text.isEmpty {
                let body = rendered.text
                textSections.append(body)
                chunkCount += rendered.chunkCount
                remainingCharacters = max(remainingCharacters - body.count, 0)
            }
        }

        for attachment in readyAttachments where attachment.kind == .image {
            try Task.checkCancellation()
            let canonical = try await canonicalReference(for: attachment)
            guard images.count < Self.maximumVisionImages else { continue }
            let data = try normalizedImageData(for: canonical.id)
            guard visionBytes + data.count <= Self.maximumVisionPayloadBytes else {
                continue
            }
            images.append(data.base64EncodedString())
            visionBytes += data.count
        }

        let manifest = readyAttachments.enumerated().map { offset, attachment in
            "\(offset + 1). \(attachment.displayName) (\(attachment.kind.rawValue))"
        }.joined(separator: "\n")
        var text = ""
        if !readyAttachments.isEmpty {
            text = """
            The user explicitly attached \(readyAttachments.count) local file(s). All listed files are available. Consider every relevant attachment and never claim a listed file is unavailable.

            Attachment manifest:
            \(manifest)
            """
        }
        if !profileText.isEmpty {
            text += "\n\nLocal-model document profiles (derived navigation only; verify claims against the raw excerpts):\n\n"
                + profileText
        }
        if !textSections.isEmpty {
            text += "\n\nLocal attachment excerpts:\n\n"
                + textSections.joined(separator: "\n\n---\n\n")
        }
        let estimated = max(text.utf8.count / 3, 0) + images.count * 2_048
        return AttachmentContext(
            text: text,
            images: images,
            chunkCount: chunkCount,
            profileCount: readyAttachments.filter { profiles[$0.id] != nil }.count,
            estimatedTokens: estimated
        )
    }

    public func deleteFromLibrary(id: UUID) async throws {
        let deletedMarker = deletedDocumentMarker(for: id)
        if !fileManager.fileExists(atPath: deletedMarker.path) {
            try Data().write(to: deletedMarker, options: .atomic)
        }
        let marker = pendingDeleteMarker(for: id)
        if !fileManager.fileExists(atPath: marker.path) {
            try Data().write(to: marker, options: .atomic)
        }
        try await completePendingDelete(id: id, marker: marker)
    }

    private func completePendingDelete(id: UUID, marker: URL) async throws {
        let target: URL
        if let record = try await libraryStore.document(id: id) {
            target = try canonicalBlobURL(for: record).deletingLastPathComponent()
        } else {
            target = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        }
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
        try await libraryStore.deleteDocument(id: id)
        validatedBlobs[id] = nil
        if fileManager.fileExists(atPath: marker.path) {
            try fileManager.removeItem(at: marker)
        }
    }

    func extractedChunks(for attachmentID: UUID) async throws -> [PDFTextChunk] {
        let databaseChunks = try await libraryStore.chunks(documentID: attachmentID)
        return databaseChunks.isEmpty
            ? try loadLegacyChunks(for: attachmentID)
            : databaseChunks
    }

    func hasLocalData(for attachmentID: UUID) -> Bool {
        fileManager.fileExists(
            atPath: directory.appendingPathComponent(attachmentID.uuidString).path
        )
    }

    private func importImage(
        id: UUID,
        source: URL,
        displayName: String,
        contentType: UTType?,
        byteCount: Int64,
        digest: String
    ) throws -> AttachmentReference {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              CGImageSourceGetCount(imageSource) > 0,
              CGImageSourceCreateImageAtIndex(imageSource, 0, nil) != nil
        else { throw AttachmentStoreError.corruptImage }
        _ = try normalizedImageData(for: id)
        return AttachmentReference(
            id: id,
            displayName: displayName,
            kind: .image,
            contentTypeIdentifier: contentType?.identifier ?? UTType.image.identifier,
            byteCount: byteCount,
            sha256: digest,
            state: .ready,
            artifact: AttachmentArtifactReceipt(
                parserID: "imageio",
                parserVersion: "system",
                pageCount: 1,
                chunkCount: 1,
                characterCount: 0
            )
        )
    }

    private func importText(
        id: UUID,
        source: URL,
        displayName: String,
        contentType: UTType?,
        byteCount: Int64,
        digest: String
    ) throws -> AttachmentReference {
        let fileExtension = source.pathExtension.lowercased()
        let text: String
        if Self.richDocumentExtensions.contains(fileExtension) {
            do {
                text = try NSAttributedString(
                    url: source,
                    options: [:],
                    documentAttributes: nil
                ).string
            } catch {
                throw AttachmentStoreError.unsupportedTextEncoding
            }
        } else {
            let data = try Data(contentsOf: source, options: .mappedIfSafe)
            guard let decoded = String(data: data, encoding: .utf8) else {
                throw AttachmentStoreError.unsupportedTextEncoding
            }
            text = decoded
        }
        let normalized = text.replacingOccurrences(of: "\u{0000}", with: "")
        let chunks = Self.textChunks(from: normalized, maximumCharacters: 8_000)
        guard !chunks.isEmpty else { throw AttachmentStoreError.noExtractableText }
        try writeChunks(chunks, for: id)
        return AttachmentReference(
            id: id,
            displayName: displayName,
            kind: .text,
            contentTypeIdentifier: contentType?.identifier ?? UTType.plainText.identifier,
            byteCount: byteCount,
            sha256: digest,
            state: .ready,
            artifact: AttachmentArtifactReceipt(
                parserID: "native-text",
                parserVersion: "utf-8",
                pageCount: 1,
                chunkCount: chunks.count,
                characterCount: normalized.count
            )
        )
    }

    private func importPDF(
        id: UUID,
        source: URL,
        displayName: String,
        contentType: UTType?,
        byteCount: Int64,
        digest: String
    ) async throws -> AttachmentReference {
        guard let document = PDFDocument(url: source) else {
            throw AttachmentStoreError.corruptPDF
        }
        guard !document.isLocked else { throw AttachmentStoreError.encryptedPDF }
        let pageCount = document.pageCount
        var chunks: [PDFTextChunk] = []
        chunks.reserveCapacity(pageCount)
        var pagesWithText = 0
        for index in 0..<pageCount {
            try Task.checkCancellation()
            let text = document.page(at: index)?.string?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.count >= 20 { pagesWithText += 1 }
            if !text.isEmpty {
                chunks.append(PDFTextChunk(page: index + 1, text: text))
            }
        }
        let characters = chunks.reduce(0) { $0 + $1.text.count }
        let coverage = pageCount > 0 ? Double(pagesWithText) / Double(pageCount) : 0
        if characters >= 100, coverage >= 0.6 {
            try writeChunks(chunks, for: id)
            return AttachmentReference(
                id: id,
                displayName: displayName,
                kind: .pdf,
                contentTypeIdentifier: contentType?.identifier ?? UTType.pdf.identifier,
                byteCount: byteCount,
                sha256: digest,
                state: .ready,
                artifact: AttachmentArtifactReceipt(
                    parserID: "pdfkit-text",
                    parserVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                    pageCount: pageCount,
                    chunkCount: chunks.count,
                    characterCount: characters
                )
            )
        }

        if let advancedPDFParser {
            let parsed = try await advancedPDFParser.parsePDF(at: source)
            try writeChunks(parsed, for: id)
            let parsedCharacters = parsed.reduce(0) { $0 + $1.text.count }
            return AttachmentReference(
                id: id,
                displayName: displayName,
                kind: .pdf,
                contentTypeIdentifier: contentType?.identifier ?? UTType.pdf.identifier,
                byteCount: byteCount,
                sha256: digest,
                state: .ready,
                artifact: AttachmentArtifactReceipt(
                    parserID: advancedPDFParser.parserID,
                    parserVersion: advancedPDFParser.parserVersion,
                    pageCount: pageCount,
                    chunkCount: parsed.count,
                    characterCount: parsedCharacters
                )
            )
        }
        return AttachmentReference(
            id: id,
            displayName: displayName,
            kind: .pdf,
            contentTypeIdentifier: contentType?.identifier ?? UTType.pdf.identifier,
            byteCount: byteCount,
            sha256: digest,
            state: .advancedParserRequired,
            artifact: AttachmentArtifactReceipt(
                parserID: "pdfkit-text",
                parserVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                pageCount: pageCount,
                chunkCount: chunks.count,
                characterCount: characters
            ),
            issue: AttachmentIssue(
                code: .noExtractableText,
                message: AttachmentStoreError.noExtractableText.localizedDescription,
                retryable: false
            )
        )
    }

    private func sourceURL(for id: UUID) throws -> URL {
        let attachmentDirectory = directory.appendingPathComponent(id.uuidString)
        let contents = try fileManager.contentsOfDirectory(
            at: attachmentDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        guard let source = contents.first(where: { $0.lastPathComponent.hasPrefix("source.") })
        else { throw AttachmentStoreError.missingSource }
        return source
    }

    private func canonicalBlobURL(
        for record: DocumentLibraryRecord
    ) throws -> URL {
        let root = directory.standardizedFileURL
        let candidate = root
            .appendingPathComponent(record.blobRelativePath)
            .standardizedFileURL
        let expectedDirectory = root
            .appendingPathComponent(record.reference.id.uuidString, isDirectory: true)
            .standardizedFileURL
        guard candidate.deletingLastPathComponent() == expectedDirectory,
              candidate.lastPathComponent.hasPrefix("source.")
        else { throw DocumentLibraryError.corrupt }
        return candidate
    }

    private func repairCanonicalBlob(
        from source: URL,
        to destination: URL,
        expectedSHA256: String
    ) throws {
        let destinationDirectory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        let staged = destinationDirectory.appendingPathComponent(
            ".repair-\(UUID().uuidString)"
        )
        defer { try? fileManager.removeItem(at: staged) }
        try fileManager.copyItem(at: source, to: staged)
        guard try sha256(of: staged) == expectedSHA256 else {
            throw DocumentLibraryError.corrupt
        }
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fileManager.moveItem(at: staged, to: destination)
        }
        let normalized = destinationDirectory.appendingPathComponent("normalized.jpg")
        try? fileManager.removeItem(at: normalized)
    }

    private func normalizedImageData(for id: UUID) throws -> Data {
        let attachmentDirectory = directory.appendingPathComponent(id.uuidString)
        let normalized = attachmentDirectory.appendingPathComponent("normalized.jpg")
        if fileManager.fileExists(atPath: normalized.path) {
            let data = try Data(contentsOf: normalized, options: .mappedIfSafe)
            if let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
               CGImageSourceGetCount(imageSource) > 0,
               CGImageSourceCreateImageAtIndex(imageSource, 0, nil) != nil {
                return data
            }
            try fileManager.removeItem(at: normalized)
        }
        let source = try sourceURL(for: id)
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw AttachmentStoreError.corruptImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2_048
        ]
        let staged = attachmentDirectory.appendingPathComponent(
            ".normalized-\(UUID().uuidString).jpg"
        )
        defer { try? fileManager.removeItem(at: staged) }
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            imageSource,
            0,
            options as CFDictionary
        ),
        let destination = CGImageDestinationCreateWithURL(
            staged as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { throw AttachmentStoreError.corruptImage }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw AttachmentStoreError.corruptImage
        }
        let data = try Data(contentsOf: staged, options: .mappedIfSafe)
        guard let stagedSource = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(stagedSource) > 0,
              CGImageSourceCreateImageAtIndex(stagedSource, 0, nil) != nil
        else { throw AttachmentStoreError.corruptImage }
        if fileManager.fileExists(atPath: normalized.path) {
            _ = try fileManager.replaceItemAt(normalized, withItemAt: staged)
        } else {
            try fileManager.moveItem(at: staged, to: normalized)
        }
        return data
    }

    private func writeChunks(_ chunks: [PDFTextChunk], for id: UUID) throws {
        let output = directory
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("chunks.jsonl")
        var data = Data()
        let encoder = JSONEncoder()
        for chunk in chunks {
            data.append(try encoder.encode(chunk))
            data.append(0x0A)
        }
        try data.write(to: output, options: .atomic)
    }

    private func loadLegacyChunks(for id: UUID) throws -> [PDFTextChunk] {
        let input = directory
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("chunks.jsonl")
        guard fileManager.fileExists(atPath: input.path) else { return [] }
        let data = try Data(contentsOf: input, options: .mappedIfSafe)
        return try data.split(separator: 0x0A).map {
            try JSONDecoder().decode(PDFTextChunk.self, from: Data($0))
        }
    }

    public func libraryDocuments(
        matching query: String = ""
    ) async throws -> [DocumentLibraryRecord] {
        try await libraryStore.documents(matching: query)
    }

    public func deletedDocumentIDs() throws -> Set<UUID> {
        let directory = self.directory.appendingPathComponent(
            Self.deletedDocumentsDirectoryName,
            isDirectory: true
        )
        let markers = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return Set(markers.compactMap { UUID(uuidString: $0.lastPathComponent) })
    }

    public func reconcilePendingImports() async throws {
        let pendingDeleteDirectory = directory.appendingPathComponent(
            Self.pendingDeletesDirectoryName,
            isDirectory: true
        )
        let pendingDeletes = try fileManager.contentsOfDirectory(
            at: pendingDeleteDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for marker in pendingDeletes {
            try Task.checkCancellation()
            guard let id = UUID(uuidString: marker.lastPathComponent) else {
                continue
            }
            try await completePendingDelete(id: id, marker: marker)
        }
        let candidates = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for candidate in candidates {
            try Task.checkCancellation()
            guard let id = UUID(uuidString: candidate.lastPathComponent) else {
                continue
            }
            let marker = candidate.appendingPathComponent(Self.pendingImportMarker)
            guard fileManager.fileExists(atPath: marker.path) else { continue }
            if let record = try await libraryStore.document(id: id) {
                try await validateStoredMaterial(record)
                if record.reference.state == .ready,
                   record.reference.kind != .image,
                   try await libraryStore.chunks(documentID: id).isEmpty {
                    throw DocumentLibraryError.corrupt
                }
                try fileManager.removeItem(at: marker)
            } else {
                try fileManager.removeItem(at: candidate)
            }
        }
    }

    private func pendingDeleteMarker(for id: UUID) -> URL {
        directory
            .appendingPathComponent(Self.pendingDeletesDirectoryName, isDirectory: true)
            .appendingPathComponent(id.uuidString)
    }

    private func deletedDocumentMarker(for id: UUID) -> URL {
        directory
            .appendingPathComponent(Self.deletedDocumentsDirectoryName, isDirectory: true)
            .appendingPathComponent(id.uuidString)
    }

    func close() async {
        await libraryStore.close()
    }

    public func cachedAnalysis(
        for key: DocumentAnalysisKey
    ) async throws -> StoredDocumentAnalysis? {
        try await libraryStore.analysis(for: key)
    }

    public func latestCachedAnalysis(
        documentSHA256: String,
        analyzerID: String,
        kind: String
    ) async throws -> StoredDocumentAnalysis? {
        try await libraryStore.latestAnalysis(
            documentSHA256: documentSHA256,
            analyzerID: analyzerID,
            kind: kind
        )
    }

    public func libraryReference(id: UUID) async throws -> AttachmentReference {
        guard let record = try await libraryStore.document(id: id) else {
            throw AttachmentStoreError.missingSource
        }
        try await validateStoredMaterial(record)
        return record.reference
    }

    public func saveAnalysis(_ analysis: StoredDocumentAnalysis) async throws {
        try await libraryStore.saveAnalysis(analysis)
    }

    public func analysisMaterial(
        for attachment: AttachmentReference,
        maximumTextCharacters: Int = 48_000
    ) async throws -> DocumentAnalysisMaterial {
        let canonical = try await canonicalReference(for: attachment)
        if canonical.kind == .image {
            let image = try normalizedImageData(for: canonical.id)
            return DocumentAnalysisMaterial(
                text: "Analyze the attached local image.",
                images: [image.base64EncodedString()],
                sourceChunkCount: 1,
                analyzedChunkCount: 1
            )
        }
        let chunks = try await storedChunks(for: canonical)
        let sampled = balancedSample(
            chunks,
            maximumCharacters: maximumTextCharacters
        )
        let locationName = canonical.kind == .pdf ? "page" : "section"
        let text = sampled.map {
            "[\(locationName) \($0.page)]\n\($0.text)"
        }.joined(separator: "\n\n---\n\n")
        return DocumentAnalysisMaterial(
            text: text,
            images: [],
            sourceChunkCount: chunks.count,
            analyzedChunkCount: sampled.count
        )
    }

    private func canonicalReference(
        for attachment: AttachmentReference
    ) async throws -> AttachmentReference {
        if let stored = try await libraryStore.document(id: attachment.id) {
            try await validateStoredMaterial(stored)
            return stored.reference
        }
        if let stored = try await libraryStore.document(withSHA256: attachment.sha256) {
            try await validateStoredMaterial(stored)
            return stored.reference
        }
        let source = try? sourceURL(for: attachment.id)
        var migratedReference = attachment
        var legacyChunks = attachment.kind == .image
            ? []
            : try loadLegacyChunks(for: attachment.id)
        guard source != nil || !legacyChunks.isEmpty else {
            throw AttachmentStoreError.missingSource
        }
        guard let source else { return attachment }
        guard try sha256(of: source) == attachment.sha256 else {
            throw AttachmentStoreError.sourceIntegrityMismatch
        }
        if legacyChunks.isEmpty {
            let contentType = UTType(attachment.contentTypeIdentifier)
            switch attachment.kind {
            case .image:
                migratedReference = try importImage(
                    id: attachment.id,
                    source: source,
                    displayName: attachment.displayName,
                    contentType: contentType,
                    byteCount: attachment.byteCount,
                    digest: attachment.sha256
                )
            case .pdf:
                migratedReference = try await importPDF(
                    id: attachment.id,
                    source: source,
                    displayName: attachment.displayName,
                    contentType: contentType,
                    byteCount: attachment.byteCount,
                    digest: attachment.sha256
                )
                legacyChunks = try loadLegacyChunks(for: attachment.id)
            case .text:
                migratedReference = try importText(
                    id: attachment.id,
                    source: source,
                    displayName: attachment.displayName,
                    contentType: contentType,
                    byteCount: attachment.byteCount,
                    digest: attachment.sha256
                )
                legacyChunks = try loadLegacyChunks(for: attachment.id)
            }
        }
        let stored = try await libraryStore.insertOrFetch(
            migratedReference,
            blobRelativePath: relativeSourcePath(for: attachment.id),
            chunks: legacyChunks
        )
        validatedBlobs[stored.reference.id] = try blobFingerprint(source)
        return stored.reference
    }

    private func validateStoredMaterial(
        _ record: DocumentLibraryRecord
    ) async throws {
        let source = try canonicalBlobURL(for: record)
        guard fileManager.fileExists(atPath: source.path) else {
            throw AttachmentStoreError.missingSource
        }
        let fingerprint = try blobFingerprint(source)
        guard try sha256(of: source) == record.reference.sha256 else {
            throw AttachmentStoreError.sourceIntegrityMismatch
        }
        validatedBlobs[record.id] = fingerprint
    }

    private func blobFingerprint(_ url: URL) throws -> BlobFingerprint {
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey
        ])
        return BlobFingerprint(
            byteCount: Int64(values.fileSize ?? 0),
            modifiedAt: values.contentModificationDate
        )
    }

    private func storedChunks(
        for attachment: AttachmentReference
    ) async throws -> [PDFTextChunk] {
        let stored = try await libraryStore.chunks(documentID: attachment.id)
        if !stored.isEmpty { return stored }
        let legacy = try loadLegacyChunks(for: attachment.id)
        if !legacy.isEmpty {
            try await libraryStore.replaceChunks(
                documentID: attachment.id,
                chunks: legacy
            )
        }
        return legacy
    }

    private func reference(
        _ canonical: AttachmentReference,
        displayName: String
    ) -> AttachmentReference {
        AttachmentReference(
            id: canonical.id,
            displayName: displayName,
            kind: canonical.kind,
            contentTypeIdentifier: canonical.contentTypeIdentifier,
            byteCount: canonical.byteCount,
            sha256: canonical.sha256,
            state: canonical.state,
            artifact: canonical.artifact,
            issue: canonical.issue
        )
    }

    private func relativeSourcePath(for id: UUID) -> String {
        guard let source = try? sourceURL(for: id) else {
            return id.uuidString
        }
        return "\(id.uuidString)/\(source.lastPathComponent)"
    }

    private func selectRelevant(
        _ chunks: [PDFTextChunk],
        query: String,
        maximumCharacters: Int
    ) -> [PDFTextChunk] {
        guard maximumCharacters > 0 else { return [] }
        let terms = Set(
            query.lowercased().split { !$0.isLetter && !$0.isNumber }
                .filter { $0.count >= 2 }
                .map(String.init)
        )
        let ranked = chunks.enumerated().map { offset, chunk in
            let lower = chunk.text.lowercased()
            let score = terms.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }
            return (offset: offset, chunk: chunk, score: score)
        }.sorted {
            if $0.score == $1.score { return $0.offset < $1.offset }
            return $0.score > $1.score
        }
        var selected: [PDFTextChunk] = []
        var used = 0
        for candidate in ranked {
            let remaining = maximumCharacters - used
            guard remaining > 0 else { break }
            let text = String(candidate.chunk.text.prefix(remaining))
            selected.append(PDFTextChunk(page: candidate.chunk.page, text: text))
            used += text.count
        }
        return selected.sorted { $0.page < $1.page }
    }

    private func balancedSample(
        _ chunks: [PDFTextChunk],
        maximumCharacters: Int
    ) -> [PDFTextChunk] {
        guard !chunks.isEmpty, maximumCharacters > 0 else { return [] }
        let sampleCount = min(chunks.count, 16)
        let indices: [Int]
        if sampleCount == 1 {
            indices = [0]
        } else {
            let interval = Double(chunks.count - 1) / Double(sampleCount - 1)
            indices = Array(
                Set((0..<sampleCount).map { Int((Double($0) * interval).rounded()) })
            ).sorted()
        }
        let perChunk = max(maximumCharacters / max(indices.count, 1) - 64, 1)
        var remaining = maximumCharacters
        var sampled: [PDFTextChunk] = []
        for index in indices {
            let text = String(chunks[index].text.prefix(min(perChunk, remaining)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            sampled.append(PDFTextChunk(page: chunks[index].page, text: text))
            remaining -= text.count
            if remaining <= 0 { break }
        }
        return sampled
    }

    private func renderProfiles(
        _ profiles: [UUID: DocumentProfile],
        attachments: [AttachmentReference],
        maximumCharacters: Int
    ) -> String {
        guard maximumCharacters > 0 else { return "" }
        var rendered: [String] = []
        var remaining = maximumCharacters
        for attachment in attachments {
            guard let profile = profiles[attachment.id], remaining > 0 else { continue }
            let coverage = profile.sourceChunkCount == profile.analyzedChunkCount
                ? "all sections"
                : "\(profile.analyzedChunkCount)/\(profile.sourceChunkCount) sampled sections"
            let outline = profile.outline.map { "- \($0)" }.joined(separator: "\n")
            let keywords = profile.keywords.joined(separator: ", ")
            let section = """
            [Derived profile: \(attachment.displayName); coverage: \(coverage)]
            Summary: \(profile.summary)
            Outline:
            \(outline)
            Keywords: \(keywords)
            """
            let bounded = String(section.prefix(remaining))
            guard !bounded.isEmpty else { break }
            rendered.append(bounded)
            remaining -= bounded.count
        }
        return rendered.joined(separator: "\n\n---\n\n")
    }

    private func renderSelectedChunks(
        _ chunks: [PDFTextChunk],
        attachment: AttachmentReference,
        maximumCharacters: Int
    ) -> (text: String, chunkCount: Int) {
        guard maximumCharacters > 0 else { return ("", 0) }
        let locationName = attachment.kind == .pdf ? "page" : "section"
        var parts: [String] = []
        var used = 0
        for chunk in chunks {
            let separatorCount = parts.isEmpty ? 0 : 2
            let header = "[\(attachment.displayName), \(locationName) \(chunk.page)]\n"
            let available = maximumCharacters - used - separatorCount - header.count
            guard available > 0 else { break }
            let content = String(chunk.text.prefix(available))
            guard !content.isEmpty else { continue }
            let part = header + content
            parts.append(part)
            used += separatorCount + part.count
        }
        return (parts.joined(separator: "\n\n"), parts.count)
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func defaultExtension(for kind: AttachmentKind) -> String {
        switch kind {
        case .image: "img"
        case .pdf: "pdf"
        case .text: "txt"
        }
    }

    private static func textChunks(
        from text: String,
        maximumCharacters: Int
    ) -> [PDFTextChunk] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var chunks: [PDFTextChunk] = []
        var start = trimmed.startIndex
        while start < trimmed.endIndex {
            let end = trimmed.index(
                start,
                offsetBy: maximumCharacters,
                limitedBy: trimmed.endIndex
            ) ?? trimmed.endIndex
            let chunk = String(trimmed[start..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty {
                chunks.append(PDFTextChunk(page: chunks.count + 1, text: chunk))
            }
            start = end
        }
        return chunks
    }

    private static let textFileExtensions: Set<String> = [
        "md", "markdown", "txt", "rtf", "csv", "tsv", "json", "jsonl",
        "yaml", "yml", "xml", "html", "htm", "css", "log", "ini", "toml",
        "doc", "docx", "odt",
        "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "rs", "py",
        "js", "jsx", "ts", "tsx", "java", "kt", "kts", "go", "rb", "php",
        "sh", "zsh", "sql"
    ]

    private static let richDocumentExtensions: Set<String> = [
        "rtf", "html", "htm", "doc", "docx", "odt"
    ]
}

private struct BlobFingerprint: Equatable {
    let byteCount: Int64
    let modifiedAt: Date?
}
