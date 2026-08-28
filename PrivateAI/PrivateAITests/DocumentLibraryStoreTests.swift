import Foundation
import SQLite3
import XCTest
@testable import PrivateAI

final class DocumentLibraryStoreTests: XCTestCase {
    func testContentHashDeduplicatesAcrossRestartAndPersistsChunks() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("library.sqlite3")
        let firstReference = makeReference(
            id: UUID(),
            name: "first-name.md",
            sha256: String(repeating: "a", count: 64)
        )
        var store: DocumentLibraryStore? = try DocumentLibraryStore(
            databaseURL: databaseURL
        )

        let first = try await store?.insertOrFetch(
            firstReference,
            blobRelativePath: "Blobs/aa/source.md",
            chunks: [
                PDFTextChunk(page: 1, text: "FIRST-CHUNK"),
                PDFTextChunk(page: 2, text: "SECOND-CHUNK")
            ]
        )
        XCTAssertEqual(first?.reference.id, firstReference.id)
        let healthy = try await store?.quickCheck()
        XCTAssertEqual(healthy, true)
        store = nil

        let reopened = try DocumentLibraryStore(databaseURL: databaseURL)
        let duplicateReference = makeReference(
            id: UUID(),
            name: "renamed-copy.md",
            sha256: firstReference.sha256
        )
        let duplicate = try await reopened.insertOrFetch(
            duplicateReference,
            blobRelativePath: "Blobs/ignored/source.md",
            chunks: [PDFTextChunk(page: 1, text: "MUST-NOT-REPLACE")]
        )

        XCTAssertEqual(duplicate.reference.id, firstReference.id)
        let reopenedChunks = try await reopened.chunks(
            documentID: firstReference.id
        ).map(\.text)
        XCTAssertEqual(reopenedChunks, ["FIRST-CHUNK", "SECOND-CHUNK"])
        let aliasMatches = try await reopened.documents(
            matching: "renamed-copy"
        ).map { $0.reference.id }
        XCTAssertEqual(aliasMatches, [firstReference.id])
        await reopened.close()
    }

    func testAnalysisCacheIsVersionedByContentModelAndAnalyzer() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DocumentLibraryStore(
            databaseURL: root.appendingPathComponent("library.sqlite3")
        )
        let key = DocumentAnalysisKey(
            documentSHA256: String(repeating: "b", count: 64),
            modelDigest: "model-digest-1",
            analyzerID: "document-profile",
            analyzerVersion: "1",
            kind: "summary"
        )
        _ = try await store.insertOrFetch(
            makeReference(
                id: UUID(),
                name: "analysis-owner.md",
                sha256: key.documentSHA256
            ),
            blobRelativePath: "Blobs/analysis/source.md",
            chunks: [PDFTextChunk(page: 1, text: "ANALYSIS-OWNER")]
        )
        let analysis = StoredDocumentAnalysis(
            key: key,
            payloadJSON: #"{"summary":"Cached once"}"#
        )

        try await store.saveAnalysis(analysis)

        let cached = try await store.analysis(for: key)
        XCTAssertEqual(cached?.payloadJSON, analysis.payloadJSON)
        let changedModel = DocumentAnalysisKey(
            documentSHA256: key.documentSHA256,
            modelDigest: "model-digest-2",
            analyzerID: key.analyzerID,
            analyzerVersion: key.analyzerVersion,
            kind: key.kind
        )
        let changedAnalyzer = DocumentAnalysisKey(
            documentSHA256: key.documentSHA256,
            modelDigest: key.modelDigest,
            analyzerID: key.analyzerID,
            analyzerVersion: "2",
            kind: key.kind
        )
        let modelMiss = try await store.analysis(for: changedModel)
        let analyzerMiss = try await store.analysis(for: changedAnalyzer)
        XCTAssertNil(modelMiss)
        XCTAssertNil(analyzerMiss)
        await store.close()
    }

    func testVersionOneMigrationKeepsOwnedAnalysesAndDropsOrphans() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("library.sqlite3")
        let ownedSHA = String(repeating: "1", count: 64)
        let orphanSHA = String(repeating: "2", count: 64)
        let reference = makeReference(
            id: UUID(),
            name: "migrated.md",
            sha256: ownedSHA
        )
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        let schema = """
        CREATE TABLE documents(
            id TEXT PRIMARY KEY, content_sha256 TEXT NOT NULL UNIQUE,
            reference_json TEXT NOT NULL, blob_relative_path TEXT NOT NULL UNIQUE,
            imported_at REAL NOT NULL, updated_at REAL NOT NULL
        );
        CREATE TABLE document_names(
            document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            display_name TEXT NOT NULL, imported_at REAL NOT NULL,
            UNIQUE(document_id, display_name)
        );
        CREATE TABLE chunks(
            document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL, locator INTEGER NOT NULL, text TEXT NOT NULL,
            text_sha256 TEXT NOT NULL, PRIMARY KEY(document_id, ordinal)
        );
        CREATE TABLE analyses(
            id INTEGER PRIMARY KEY AUTOINCREMENT, document_sha256 TEXT NOT NULL,
            model_digest TEXT NOT NULL, analyzer_id TEXT NOT NULL,
            analyzer_version TEXT NOT NULL, analysis_kind TEXT NOT NULL,
            payload_json TEXT NOT NULL, created_at REAL NOT NULL,
            UNIQUE(document_sha256, model_digest, analyzer_id, analyzer_version, analysis_kind)
        );
        PRAGMA user_version = 1;
        """
        XCTAssertEqual(sqlite3_exec(database, schema, nil, nil, nil), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                database,
                "INSERT INTO documents VALUES(?, ?, ?, ?, 1, 1)",
                -1,
                &statement,
                nil
            ),
            SQLITE_OK
        )
        let referenceJSON = String(
            decoding: try JSONEncoder().encode(reference),
            as: UTF8.self
        )
        sqlite3_bind_text(statement, 1, reference.id.uuidString, -1, testSQLiteTransient)
        sqlite3_bind_text(statement, 2, ownedSHA, -1, testSQLiteTransient)
        sqlite3_bind_text(statement, 3, referenceJSON, -1, testSQLiteTransient)
        sqlite3_bind_text(statement, 4, "blob/source.md", -1, testSQLiteTransient)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement)
        statement = nil
        let insertAnalysis = "INSERT INTO analyses(document_sha256, model_digest, analyzer_id, analyzer_version, analysis_kind, payload_json, created_at) VALUES(?, 'digest', 'document-profile', '1', 'summary', ?, 1)"
        XCTAssertEqual(
            sqlite3_prepare_v2(database, insertAnalysis, -1, &statement, nil),
            SQLITE_OK
        )
        sqlite3_bind_text(statement, 1, ownedSHA, -1, testSQLiteTransient)
        sqlite3_bind_text(statement, 2, "OWNED-PROFILE", -1, testSQLiteTransient)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        sqlite3_bind_text(statement, 1, orphanSHA, -1, testSQLiteTransient)
        sqlite3_bind_text(statement, 2, "ORPHAN-PROFILE", -1, testSQLiteTransient)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        sqlite3_finalize(statement)
        sqlite3_close(database)

        let store = try DocumentLibraryStore(databaseURL: databaseURL)
        let ownedKey = DocumentAnalysisKey(
            documentSHA256: ownedSHA,
            modelDigest: "digest",
            analyzerID: "document-profile",
            analyzerVersion: "1",
            kind: "summary"
        )
        let orphanKey = DocumentAnalysisKey(
            documentSHA256: orphanSHA,
            modelDigest: "digest",
            analyzerID: "document-profile",
            analyzerVersion: "1",
            kind: "summary"
        )
        let ownedAnalysis = try await store.analysis(for: ownedKey)
        let orphanAnalysis = try await store.analysis(for: orphanKey)
        XCTAssertEqual(ownedAnalysis?.payloadJSON, "OWNED-PROFILE")
        XCTAssertNil(orphanAnalysis)
        await store.close()
    }

    func testDeleteReportsBusyUntilWALCanBeTruncated() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("library.sqlite3")
        let store = try DocumentLibraryStore(databaseURL: databaseURL)
        let reference = makeReference(
            id: UUID(),
            name: "privacy-delete.md",
            sha256: String(repeating: "3", count: 64)
        )
        _ = try await store.insertOrFetch(
            reference,
            blobRelativePath: "Blobs/privacy/source.md",
            chunks: [PDFTextChunk(page: 1, text: "DELETE-PRIVACY-SENTINEL-991")]
        )
        var reader: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &reader), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(reader, "BEGIN", nil, nil, nil), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(reader, "SELECT text FROM chunks", -1, &statement, nil),
            SQLITE_OK
        )
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)

        do {
            try await store.deleteDocument(id: reference.id)
            XCTFail("Expected an active reader to block the privacy checkpoint")
        } catch DocumentLibraryError.checkpointBusy {
        } catch {
            XCTFail("Expected checkpointBusy, got \(error)")
        }
        let deletedDocument = try await store.document(id: reference.id)
        XCTAssertNil(deletedDocument)

        sqlite3_finalize(statement)
        sqlite3_exec(reader, "COMMIT", nil, nil, nil)
        sqlite3_close(reader)
        try await store.deleteDocument(id: reference.id)
        let databaseBytes = try Data(contentsOf: databaseURL)
        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        let walBytes = (try? Data(contentsOf: walURL)) ?? Data()
        XCTAssertFalse(
            String(decoding: databaseBytes + walBytes, as: UTF8.self)
                .contains("DELETE-PRIVACY-SENTINEL-991")
        )
        await store.close()
    }

    func testExplicitDocumentDeleteCascadesChunksAndAnalysis() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DocumentLibraryStore(
            databaseURL: root.appendingPathComponent("library.sqlite3")
        )
        let reference = makeReference(
            id: UUID(),
            name: "delete.md",
            sha256: String(repeating: "c", count: 64)
        )
        _ = try await store.insertOrFetch(
            reference,
            blobRelativePath: "Blobs/cc/source.md",
            chunks: [PDFTextChunk(page: 1, text: "DELETE-ME")]
        )
        let key = DocumentAnalysisKey(
            documentSHA256: reference.sha256,
            modelDigest: "digest",
            analyzerID: "document-profile",
            analyzerVersion: "1",
            kind: "summary"
        )
        try await store.saveAnalysis(
            StoredDocumentAnalysis(key: key, payloadJSON: #"{"summary":"delete"}"#)
        )

        try await store.deleteDocument(id: reference.id)

        let deletedDocument = try await store.document(id: reference.id)
        let deletedChunks = try await store.chunks(documentID: reference.id)
        let deletedAnalysis = try await store.analysis(for: key)
        XCTAssertNil(deletedDocument)
        XCTAssertTrue(deletedChunks.isEmpty)
        XCTAssertNil(deletedAnalysis)
        do {
            try await store.saveAnalysis(
                StoredDocumentAnalysis(
                    key: key,
                    payloadJSON: #"{"summary":"must-not-return"}"#
                )
            )
            XCTFail("Expected a deleted document to reject a later analysis write")
        } catch DocumentLibraryError.execute {
        } catch {
            XCTFail("Expected a foreign-key execute error, got \(error)")
        }
        await store.close()
    }

    func testConcurrentConnectionsDeduplicateOneContentHash() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("library.sqlite3")
        let firstStore = try DocumentLibraryStore(databaseURL: databaseURL)
        let secondStore = try DocumentLibraryStore(databaseURL: databaseURL)
        let sha256 = String(repeating: "d", count: 64)
        let firstReference = makeReference(
            id: UUID(),
            name: "concurrent-a.md",
            sha256: sha256
        )
        let secondReference = makeReference(
            id: UUID(),
            name: "concurrent-b.md",
            sha256: sha256
        )

        async let first = firstStore.insertOrFetch(
            firstReference,
            blobRelativePath: "Blobs/a/source.md",
            chunks: [PDFTextChunk(page: 1, text: "FIRST")]
        )
        async let second = secondStore.insertOrFetch(
            secondReference,
            blobRelativePath: "Blobs/b/source.md",
            chunks: [PDFTextChunk(page: 1, text: "SECOND")]
        )
        let (firstResult, secondResult) = try await (first, second)

        XCTAssertEqual(firstResult.reference.id, secondResult.reference.id)
        let records = try await firstStore.documents()
        XCTAssertEqual(records.count, 1)
        let storedChunks = try await firstStore.chunks(
            documentID: firstResult.reference.id
        ).map(\.text)
        XCTAssertTrue(storedChunks == ["FIRST"] || storedChunks == ["SECOND"])
        let healthy = try await firstStore.quickCheck()
        XCTAssertTrue(healthy)
        await firstStore.close()
        await secondStore.close()
    }

    func testFutureSchemaIsRejectedWithoutMutation() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("library.sqlite3")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(
            sqlite3_exec(database, "PRAGMA user_version = 999", nil, nil, nil),
            SQLITE_OK
        )
        sqlite3_close(database)
        database = nil

        XCTAssertThrowsError(try DocumentLibraryStore(databaseURL: databaseURL)) {
            guard case DocumentLibraryError.futureSchema(999) = $0 else {
                return XCTFail("Expected futureSchema(999), got \($0)")
            }
        }

        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil),
            SQLITE_OK
        )
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 999)
    }

    func testLibrarySearchMatchesAliasRawChunksAndCachedProfile() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DocumentLibraryStore(
            databaseURL: root.appendingPathComponent("library.sqlite3")
        )
        let reference = makeReference(
            id: UUID(),
            name: "planning-original.md",
            sha256: String(repeating: "f", count: 64)
        )
        _ = try await store.insertOrFetch(
            reference,
            blobRelativePath: "Blobs/search/source.md",
            chunks: [PDFTextChunk(page: 1, text: "RAW-SEARCH-HARBOR-88")]
        )
        _ = try await store.insertOrFetch(
            makeReference(
                id: UUID(),
                name: "renamed-brief.md",
                sha256: reference.sha256
            ),
            blobRelativePath: "Blobs/ignored/source.md",
            chunks: []
        )
        let key = DocumentAnalysisKey(
            documentSHA256: reference.sha256,
            modelDigest: "digest",
            analyzerID: DocumentAnalyzer.analyzerID,
            analyzerVersion: DocumentAnalyzer.analyzerVersion,
            kind: DocumentAnalyzer.analysisKind
        )
        try await store.saveAnalysis(
            StoredDocumentAnalysis(
                key: key,
                payloadJSON: #"{"summary":"PROFILE-SEARCH-ORCHID-55","outline":[],"keywords":[],"sourceChunkCount":1,"analyzedChunkCount":1}"#
            )
        )

        let aliasMatches = try await store.documents(matching: "renamed-brief")
        let rawMatches = try await store.documents(matching: "HARBOR-88")
        let profileMatches = try await store.documents(matching: "ORCHID-55")
        let misses = try await store.documents(matching: "not-present")
        XCTAssertEqual(aliasMatches.count, 1)
        XCTAssertEqual(aliasMatches.first?.reference.displayName, "renamed-brief.md")
        XCTAssertEqual(rawMatches.count, 1)
        XCTAssertEqual(profileMatches.count, 1)
        XCTAssertTrue(misses.isEmpty)
        let structuralMatches = try await store.documents(matching: "summary")
        XCTAssertTrue(structuralMatches.isEmpty)
        await store.close()
    }

    private func makeReference(
        id: UUID,
        name: String,
        sha256: String
    ) -> AttachmentReference {
        AttachmentReference(
            id: id,
            displayName: name,
            kind: .text,
            contentTypeIdentifier: "net.daringfireball.markdown",
            byteCount: 128,
            sha256: sha256,
            state: .ready,
            artifact: AttachmentArtifactReceipt(
                parserID: "native-text",
                parserVersion: "utf-8",
                pageCount: 1,
                chunkCount: 2,
                characterCount: 24
            )
        )
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateAI-DocumentLibrary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }
}

private let testSQLiteTransient = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)