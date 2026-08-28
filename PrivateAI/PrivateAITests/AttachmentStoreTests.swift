import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PrivateAI

final class AttachmentStoreTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        ScriptedURLProtocol.reset()
        for root in roots {
            try? FileManager.default.removeItem(at: root)
        }
        roots = []
        super.tearDown()
    }

    func testTextPDFIsCopiedExtractedAndRetrievedByPage() async throws {
        let root = try makeRoot()
        let source = root.appendingPathComponent("source.pdf")
        try makePDF(
            at: source,
            pages: [
                "Page one discusses apples and pears.",
                "Page two contains the project codename HARBOR-LANTERN.",
                "Page three discusses oranges and grapes."
            ]
        )
        let store = try makeStore(root: root)

        let attachment = try await store.importFile(at: source)
        let context = try await store.context(
            for: [attachment],
            query: "What is the project codename?",
            maximumTextCharacters: 300
        )

        XCTAssertEqual(attachment.kind, .pdf)
        XCTAssertEqual(attachment.state, .ready)
        XCTAssertEqual(attachment.artifact?.parserID, "pdfkit-text")
        XCTAssertEqual(attachment.artifact?.pageCount, 3)
        XCTAssertTrue(context.text.contains("page 2"))
        XCTAssertTrue(context.text.contains("HARBOR-LANTERN"))
        XCTAssertLessThanOrEqual(context.text.count, 500)
        XCTAssertFalse(attachment.sha256.isEmpty)
        XCTAssertFalse(attachment.sha256 == String(repeating: "0", count: 64))
    }

    func testMarkdownFileIsCopiedChunkedAndRetrievedLocally() async throws {
        let root = try makeRoot()
        let source = root.appendingPathComponent("word-online-snapshot.md")
        let markdown = """
        # Microsoft Scout snapshot

        General introduction text.

        ## Editing capability

        The local snapshot says the editor preserves tracked changes and comments.
        """
        try Data(markdown.utf8).write(to: source)
        let store = try makeStore(root: root)

        let attachment = try await store.importFile(at: source)
        let context = try await store.context(
            for: [attachment],
            query: "Does the editor preserve tracked changes?"
        )

        XCTAssertEqual(attachment.kind, .text)
        XCTAssertEqual(attachment.state, .ready)
        XCTAssertEqual(attachment.artifact?.parserID, "native-text")
        XCTAssertEqual(attachment.artifact?.pageCount, 1)
        XCTAssertTrue(context.text.contains("word-online-snapshot.md"))
        XCTAssertTrue(context.text.contains("tracked changes and comments"))
        XCTAssertTrue(context.text.contains("section 1"))
        XCTAssertTrue(context.images.isEmpty)
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 0)
    }

    func testMultipleTextAttachmentsEachReceiveContextBudget() async throws {
        let root = try makeRoot()
        let firstURL = root.appendingPathComponent("first.md")
        let secondURL = root.appendingPathComponent("README.md")
        try Data(
            ("FIRST-FILE-MARKER-ORCHID-17\n" + String(repeating: "First file text. ", count: 300)).utf8
        ).write(to: firstURL)
        try Data(
            ("SECOND-FILE-MARKER-HARBOR-29\n" + String(repeating: "Second file text. ", count: 300)).utf8
        ).write(to: secondURL)
        let store = try makeStore(root: root)
        let first = try await store.importFile(at: firstURL)
        let second = try await store.importFile(at: secondURL)

        let context = try await store.context(
            for: [first, second],
            query: "Summarize both files",
            maximumTextCharacters: 800
        )

        XCTAssertTrue(context.text.contains("The user explicitly attached 2 local file(s)"))
        XCTAssertTrue(context.text.contains("1. first.md (text)"))
        XCTAssertTrue(context.text.contains("2. README.md (text)"))
        XCTAssertTrue(context.text.contains("FIRST-FILE-MARKER-ORCHID-17"))
        XCTAssertTrue(context.text.contains("SECOND-FILE-MARKER-HARBOR-29"))
        XCTAssertGreaterThanOrEqual(context.chunkCount, 2)
    }

    func testDuplicateImportRepairsMissingCanonicalBlob() async throws {
        let root = try makeRoot()
        let source = root.appendingPathComponent("repair.md")
        let contents = "# Durable document\n\nCANONICAL-BLOB-REPAIR-41"
        try Data(contents.utf8).write(to: source)
        let store = try makeStore(root: root)

        let first = try await store.importFile(at: source)
        let canonicalDirectory = root
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent(first.id.uuidString, isDirectory: true)
        try FileManager.default.removeItem(at: canonicalDirectory)

        let duplicate = try await store.importFile(at: source)

        XCTAssertEqual(duplicate.id, first.id)
        let repairedBlobExists = await store.hasLocalData(for: first.id)
        XCTAssertTrue(repairedBlobExists)
        let repairedContext = try await store.context(
            for: [duplicate],
            query: "What marker is in the document?"
        )
        XCTAssertTrue(repairedContext.text.contains("CANONICAL-BLOB-REPAIR-41"))
    }

    func testReconcilePendingImportsRemovesOnlyMarkedOrphans() async throws {
        let root = try makeRoot()
        let store = try makeStore(root: root)
        let attachments = root.appendingPathComponent("Attachments", isDirectory: true)
        let orphan = attachments
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let legacy = attachments
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: orphan,
            withIntermediateDirectories: true
        )
        try Data().write(to: orphan.appendingPathComponent(".pending-import"))
        try FileManager.default.createDirectory(
            at: legacy,
            withIntermediateDirectories: true
        )
        try Data("legacy".utf8).write(
            to: legacy.appendingPathComponent("source.md")
        )

        try await store.reconcilePendingImports()

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        await store.close()
    }

    func testReconcileCompletesInterruptedLibraryDelete() async throws {
        let root = try makeRoot()
        let attachments = root.appendingPathComponent("Attachments", isDirectory: true)
        let store = try AttachmentStore(directory: attachments)
        let source = root.appendingPathComponent("delete-recovery.md")
        try Data("DELETE-RECOVERY-RAW-62".utf8).write(to: source)
        let attachment = try await store.importFile(at: source)
        let analysisKey = DocumentAnalysisKey(
            documentSHA256: attachment.sha256,
            modelDigest: "digest",
            analyzerID: DocumentAnalyzer.analyzerID,
            analyzerVersion: DocumentAnalyzer.analyzerVersion,
            kind: DocumentAnalyzer.analysisKind
        )
        try await store.saveAnalysis(
            StoredDocumentAnalysis(
                key: analysisKey,
                payloadJSON: #"{"summary":"DELETE-RECOVERY-PROFILE"}"#
            )
        )
        let marker = attachments
            .appendingPathComponent("PendingDeletes", isDirectory: true)
            .appendingPathComponent(attachment.id.uuidString)
        try Data().write(to: marker, options: .atomic)
        try FileManager.default.removeItem(
            at: attachments.appendingPathComponent(
                attachment.id.uuidString,
                isDirectory: true
            )
        )

        try await store.reconcilePendingImports()

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let documents = try await store.libraryDocuments()
        let chunks = try await store.extractedChunks(for: attachment.id)
        let cachedAnalysis = try await store.cachedAnalysis(for: analysisKey)
        XCTAssertTrue(documents.isEmpty)
        XCTAssertTrue(chunks.isEmpty)
        XCTAssertNil(cachedAnalysis)
        await store.close()
    }

    func testMissingLegacyDataDoesNotCreateLibraryRecord() async throws {
        let root = try makeRoot()
        let store = try makeStore(root: root)
        let missing = AttachmentReference(
            id: UUID(),
            displayName: "missing.md",
            kind: .text,
            contentTypeIdentifier: UTType.plainText.identifier,
            byteCount: 42,
            sha256: String(repeating: "e", count: 64),
            state: .ready,
            artifact: AttachmentArtifactReceipt(
                parserID: "native-text",
                parserVersion: "utf-8",
                pageCount: 1,
                chunkCount: 1,
                characterCount: 42
            )
        )

        do {
            _ = try await store.context(for: [missing], query: "read")
            XCTFail("Expected missing local data to fail")
        } catch AttachmentStoreError.missingSource {
        } catch {
            XCTFail("Expected missingSource, got \(error)")
        }
        let records = try await store.libraryDocuments()
        XCTAssertTrue(records.isEmpty)
        await store.close()
    }

    func testTamperedStoredBlobIsRejectedAfterRestart() async throws {
        let root = try makeRoot()
        let attachments = root.appendingPathComponent("Attachments", isDirectory: true)
        var store: AttachmentStore? = try AttachmentStore(directory: attachments)
        let source = root.appendingPathComponent("trusted.md")
        try Data("TRUSTED-CONTENT-17".utf8).write(to: source)
        let attachment = try await store?.importFile(at: source)
        let imported = try XCTUnwrap(attachment)
        await store?.close()
        store = nil
        let canonical = attachments
            .appendingPathComponent(imported.id.uuidString, isDirectory: true)
            .appendingPathComponent("source.md")
        try Data("TAMPERED-CONTENT-WITH-DIFFERENT-SIZE".utf8).write(
            to: canonical,
            options: .atomic
        )
        let reopened = try AttachmentStore(directory: attachments)

        do {
            _ = try await reopened.context(
                for: [imported],
                query: "Read the content"
            )
            XCTFail("Expected source integrity validation to fail")
        } catch AttachmentStoreError.sourceIntegrityMismatch {
        } catch {
            XCTFail("Expected sourceIntegrityMismatch, got \(error)")
        }
        await reopened.close()
    }

    func testPostCopySizeCheckRejectsAFileThatGrew() async throws {
        let root = try makeRoot()
        let source = root.appendingPathComponent("growing.md")
        try Data("small before copy".utf8).write(to: source)
        let fileManager = ExpandingCopyFileManager(
            copiedSize: UInt64(AttachmentStore.maximumTextBytes + 1)
        )
        let store = try AttachmentStore(
            directory: root.appendingPathComponent("Attachments"),
            fileManager: fileManager
        )

        do {
            _ = try await store.importFile(at: source)
            XCTFail("Expected the copied file size to be enforced")
        } catch AttachmentStoreError.fileTooLarge(let maximumBytes) {
            XCTAssertEqual(maximumBytes, AttachmentStore.maximumTextBytes)
        } catch {
            XCTFail("Expected fileTooLarge, got \(error)")
        }
        let documents = try await store.libraryDocuments()
        XCTAssertTrue(documents.isEmpty)
        await store.close()
    }

    func testSourceCodeFileUsesNativeTextParser() async throws {
        let root = try makeRoot()
        let source = root.appendingPathComponent("Example.swift")
        try Data("struct Example { let value = 42 }".utf8).write(to: source)
        let store = try makeStore(root: root)

        let attachment = try await store.importFile(at: source)

        XCTAssertEqual(attachment.kind, .text)
        XCTAssertEqual(attachment.contentTypeIdentifier.isEmpty, false)
        XCTAssertEqual(attachment.artifact?.parserID, "native-text")
    }

    func testRTFUsesNativeRichTextImporter() async throws {
        let root = try makeRoot()
        let source = root.appendingPathComponent("notes.rtf")
        try Data(#"{\rtf1\ansi PrivateAI rich text value 73.}"#.utf8).write(to: source)
        let store = try makeStore(root: root)

        let attachment = try await store.importFile(at: source)
        let context = try await store.context(
            for: [attachment],
            query: "What is the rich text value?"
        )

        XCTAssertEqual(attachment.kind, .text)
        XCTAssertTrue(context.text.contains("PrivateAI rich text value 73."))
        XCTAssertFalse(context.text.contains("rtf1"))
    }

    func testImageIsNormalizedBeforeVisionContext() async throws {
        let root = try makeRoot()
        let source = root.appendingPathComponent("red.png")
        try makeRedImage(at: source, width: 320, height: 180)
        let store = try makeStore(root: root)

        let attachment = try await store.importFile(at: source)
        let context = try await store.context(
            for: [attachment],
            query: "What color is the image?"
        )

        XCTAssertEqual(attachment.kind, .image)
        XCTAssertEqual(attachment.state, .ready)
        XCTAssertEqual(attachment.artifact?.parserID, "imageio")
        XCTAssertEqual(context.images.count, 1)
        let normalized = try XCTUnwrap(Data(base64Encoded: context.images[0]))
        XCTAssertLessThan(normalized.count, 12 * 1_024 * 1_024)
        XCTAssertNotNil(CGImageSourceCreateWithData(normalized as CFData, nil))
    }

    func testImageOnlyPDFIsExplicitlyUnsupportedWithoutNativeParser() async throws {
        let root = try makeRoot()
        let source = root.appendingPathComponent("scanned.pdf")
        try makePDF(at: source, pages: [""])
        let store = try makeStore(root: root)

        let attachment = try await store.importFile(at: source)

        XCTAssertEqual(attachment.state, .advancedParserRequired)
        XCTAssertEqual(attachment.issue?.code, .noExtractableText)
        XCTAssertFalse(attachment.issue?.retryable == true)
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 0)
    }

    func testBundledNativeParserSeamConvertsScannedPDFInProcess() async throws {
        let root = try makeRoot()
        let source = root.appendingPathComponent("scanned.pdf")
        try makePDF(at: source, pages: [""])
        let store = try AttachmentStore(
            directory: root.appendingPathComponent("Attachments"),
            advancedPDFParser: FakeNativePDFParser(
                chunks: [
                    PDFTextChunk(page: 1, text: "Native parser page one."),
                    PDFTextChunk(page: 2, text: "Native parser page two table.")
                ]
            )
        )

        let attachment = try await store.importFile(at: source)
        let context = try await store.context(
            for: [attachment],
            query: "table"
        )

        XCTAssertEqual(attachment.state, .ready)
        XCTAssertEqual(attachment.artifact?.parserID, "bundled-native-test")
        XCTAssertEqual(attachment.artifact?.pageCount, 1)
        XCTAssertEqual(attachment.artifact?.chunkCount, 2)
        XCTAssertTrue(context.text.contains("Native parser page two table"))
        XCTAssertEqual(ScriptedURLProtocol.requestCount, 0)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateAI-Attachment-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    private func makeStore(root: URL) throws -> AttachmentStore {
        try AttachmentStore(
            directory: root.appendingPathComponent("Attachments")
        )
    }

    private func makePDF(at url: URL, pages: [String]) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for text in pages {
            context.beginPDFPage(nil)
            if !text.isEmpty {
                let line = CTLineCreateWithAttributedString(
                    NSAttributedString(
                        string: text,
                        attributes: [
                            .font: NSFont.systemFont(ofSize: 18),
                            .foregroundColor: NSColor.black
                        ]
                    )
                )
                context.textPosition = CGPoint(x: 54, y: 700)
                CTLineDraw(line, context)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    private func makeRedImage(at url: URL, width: Int, height: Int) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.coderInvalidValue) }
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
              )
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

private final class ExpandingCopyFileManager: FileManager, @unchecked Sendable {
    private let copiedSize: UInt64

    init(copiedSize: UInt64) {
        self.copiedSize = copiedSize
        super.init()
    }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        try super.copyItem(at: srcURL, to: dstURL)
        let handle = try FileHandle(forWritingTo: dstURL)
        defer { try? handle.close() }
        try handle.truncate(atOffset: copiedSize)
    }
}

private struct FakeNativePDFParser: AdvancedPDFParsing {
    let parserID = "bundled-native-test"
    let parserVersion = "1"
    let chunks: [PDFTextChunk]

    func parsePDF(at url: URL) async throws -> [PDFTextChunk] {
        chunks
    }
}
