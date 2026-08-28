import CryptoKit
import Foundation
import SQLite3

public struct DocumentLibraryRecord: Equatable, Identifiable, Sendable {
    public var id: UUID { reference.id }
    public let reference: AttachmentReference
    public let importedAt: Date
    public let blobRelativePath: String

    public init(
        reference: AttachmentReference,
        importedAt: Date,
        blobRelativePath: String
    ) {
        self.reference = reference
        self.importedAt = importedAt
        self.blobRelativePath = blobRelativePath
    }
}

public struct DocumentAnalysisKey: Equatable, Hashable, Sendable {
    public let documentSHA256: String
    public let modelDigest: String
    public let analyzerID: String
    public let analyzerVersion: String
    public let kind: String

    public init(
        documentSHA256: String,
        modelDigest: String,
        analyzerID: String,
        analyzerVersion: String,
        kind: String
    ) {
        self.documentSHA256 = documentSHA256
        self.modelDigest = modelDigest
        self.analyzerID = analyzerID
        self.analyzerVersion = analyzerVersion
        self.kind = kind
    }
}

public struct StoredDocumentAnalysis: Equatable, Sendable {
    public let key: DocumentAnalysisKey
    public let payloadJSON: String
    public let createdAt: Date

    public init(
        key: DocumentAnalysisKey,
        payloadJSON: String,
        createdAt: Date = Date()
    ) {
        self.key = key
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
    }
}

public enum DocumentLibraryError: LocalizedError, Sendable {
    case open(String)
    case statement(String)
    case execute(String)
    case corrupt
    case futureSchema(Int)
    case checkpointBusy

    public var errorDescription: String? {
        switch self {
        case .open(let message): String(localized: "Could not open the local document library: \(message)")
        case .statement(let message): String(localized: "Could not prepare the document library: \(message)")
        case .execute(let message): String(localized: "Could not update the document library: \(message)")
        case .corrupt: String(localized: "The local document library returned invalid data.")
        case .futureSchema(let version):
            String(localized: "The document library uses newer schema version \(version). Update PrivateAI before opening it.")
        case .checkpointBusy:
            String(localized: "The document was deleted, but PrivateAI is still finishing secure local cleanup. Close other PrivateAI windows and retry.")
        }
    }
}

public actor DocumentLibraryStore {
    public static let schemaVersion = 2

    private let databaseURL: URL
    private let connection: SQLiteConnection
    private var database: OpaquePointer { connection.handle }
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK,
              let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) }
                ?? "unknown error"
            if let handle { sqlite3_close(handle) }
            throw DocumentLibraryError.open(message)
        }
        let connection = SQLiteConnection(handle: handle)
        self.connection = connection
        do {
            try Self.configure(handle)
            try Self.migrate(handle)
            guard try Self.quickCheck(handle) else {
                throw DocumentLibraryError.corrupt
            }
        } catch {
            throw error
        }
    }

    public func document(withSHA256 sha256: String) throws -> DocumentLibraryRecord? {
        try queryDocument(
            sql: "SELECT reference_json, imported_at, blob_relative_path FROM documents WHERE content_sha256 = ? LIMIT 1",
            value: sha256
        )
    }

    public func document(id: UUID) throws -> DocumentLibraryRecord? {
        try queryDocument(
            sql: "SELECT reference_json, imported_at, blob_relative_path FROM documents WHERE id = ? LIMIT 1",
            value: id.uuidString
        )
    }

    @discardableResult
    public func insertOrFetch(
        _ reference: AttachmentReference,
        blobRelativePath: String,
        chunks: [PDFTextChunk]
    ) throws -> DocumentLibraryRecord {
        if let existing = try document(withSHA256: reference.sha256) {
            try rememberName(reference.displayName, for: existing.reference.id)
            return existing
        }

        let importedAt = Date()
        let referenceJSON = String(
            decoding: try encoder.encode(reference),
            as: UTF8.self
        )
        return try transaction {
            let inserted = try executeReturningChanges(
                """
                INSERT OR IGNORE INTO documents(
                    id, content_sha256, reference_json, blob_relative_path,
                    imported_at, updated_at
                ) VALUES(?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(reference.id.uuidString),
                    .text(reference.sha256),
                    .text(referenceJSON),
                    .text(blobRelativePath),
                    .double(importedAt.timeIntervalSince1970),
                    .double(importedAt.timeIntervalSince1970)
                ]
            )
            if inserted == 0 {
                guard let existing = try document(withSHA256: reference.sha256) else {
                    throw DocumentLibraryError.corrupt
                }
                try rememberName(reference.displayName, for: existing.reference.id)
                return existing
            }
            try execute(
                "INSERT OR IGNORE INTO document_names(document_id, display_name, imported_at) VALUES(?, ?, ?)",
                bindings: [
                    .text(reference.id.uuidString),
                    .text(reference.displayName),
                    .double(importedAt.timeIntervalSince1970)
                ]
            )
            try replaceChunksWithinTransaction(reference.id, chunks: chunks)
            return DocumentLibraryRecord(
                reference: reference,
                importedAt: importedAt,
                blobRelativePath: blobRelativePath
            )
        }
    }

    public func replaceChunks(
        documentID: UUID,
        chunks: [PDFTextChunk]
    ) throws {
        try transaction {
            try replaceChunksWithinTransaction(documentID, chunks: chunks)
        }
    }

    public func chunks(documentID: UUID) throws -> [PDFTextChunk] {
        let statement = try prepare(
            "SELECT locator, text, text_sha256 FROM chunks WHERE document_id = ? ORDER BY ordinal"
        )
        defer { sqlite3_finalize(statement) }
        try bind(.text(documentID.uuidString), to: statement, index: 1)
        var chunks: [PDFTextChunk] = []
        var result = try step(statement)
        while result == SQLITE_ROW {
            let page = Int(sqlite3_column_int64(statement, 0))
            guard let textPointer = sqlite3_column_text(statement, 1),
                  let digestPointer = sqlite3_column_text(statement, 2)
            else {
                throw DocumentLibraryError.corrupt
            }
            let text = String(cString: textPointer)
            guard Self.textDigest(text) == String(cString: digestPointer) else {
                throw DocumentLibraryError.corrupt
            }
            chunks.append(
                PDFTextChunk(page: page, text: text)
            )
            result = try step(statement)
        }
        return chunks
    }

    public func documents(matching query: String = "") throws -> [DocumentLibraryRecord] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let sql: String
        let binding: SQLiteBinding?
        if normalized.isEmpty {
            sql = """
                SELECT d.reference_json, d.imported_at, d.blob_relative_path,
                       (SELECT n.display_name FROM document_names n
                        WHERE n.document_id = d.id
                        ORDER BY n.imported_at DESC LIMIT 1) AS latest_name
                FROM documents d ORDER BY d.updated_at DESC
                """
            binding = nil
        } else {
            sql = """
                SELECT d.reference_json, d.imported_at, d.blob_relative_path,
                       (SELECT n.display_name FROM document_names n
                        WHERE n.document_id = d.id
                        ORDER BY n.imported_at DESC LIMIT 1) AS latest_name
                FROM documents d
                WHERE EXISTS(
                    SELECT 1 FROM document_names n
                    WHERE n.document_id = d.id AND n.display_name LIKE ? ESCAPE '\\'
                ) OR EXISTS(
                    SELECT 1 FROM chunks c
                    WHERE c.document_id = d.id AND c.text LIKE ? ESCAPE '\\'
                ) OR EXISTS(
                    SELECT 1 FROM analyses a
                    WHERE a.document_sha256 = d.content_sha256
                      AND (
                          CASE WHEN json_valid(a.payload_json)
                               THEN json_extract(a.payload_json, '$.summary')
                          END LIKE ? ESCAPE '\\'
                          OR EXISTS(
                              SELECT 1 FROM json_each(
                                  CASE WHEN json_valid(a.payload_json)
                                       THEN a.payload_json ELSE '{}' END,
                                  '$.outline'
                              )
                              WHERE json_each.value LIKE ? ESCAPE '\\'
                          )
                          OR EXISTS(
                              SELECT 1 FROM json_each(
                                  CASE WHEN json_valid(a.payload_json)
                                       THEN a.payload_json ELSE '{}' END,
                                  '$.keywords'
                              )
                              WHERE json_each.value LIKE ? ESCAPE '\\'
                          )
                      )
                )
                ORDER BY d.updated_at DESC
                """
            binding = .text("%\(Self.escapeLike(normalized))%")
        }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        if let binding {
            let bindingCount = normalized.isEmpty ? 1 : 5
            for index in 1...bindingCount {
                try bind(binding, to: statement, index: Int32(index))
            }
        }
        var records: [DocumentLibraryRecord] = []
        var result = try step(statement)
        while result == SQLITE_ROW {
            records.append(try decodeRecord(statement))
            result = try step(statement)
        }
        return records
    }

    public func analysis(for key: DocumentAnalysisKey) throws -> StoredDocumentAnalysis? {
        let statement = try prepare(
            """
            SELECT payload_json, created_at FROM analyses
            WHERE document_sha256 = ? AND model_digest = ? AND analyzer_id = ?
              AND analyzer_version = ? AND analysis_kind = ?
            LIMIT 1
            """
        )
        defer { sqlite3_finalize(statement) }
        let values: [SQLiteBinding] = [
            .text(key.documentSHA256), .text(key.modelDigest),
            .text(key.analyzerID), .text(key.analyzerVersion), .text(key.kind)
        ]
        for (offset, value) in values.enumerated() {
            try bind(value, to: statement, index: Int32(offset + 1))
        }
        let result = try step(statement)
        guard result == SQLITE_ROW else { return nil }
        guard let payload = sqlite3_column_text(statement, 0) else {
            throw DocumentLibraryError.corrupt
        }
        return StoredDocumentAnalysis(
            key: key,
            payloadJSON: String(cString: payload),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
        )
    }

    public func latestAnalysis(
        documentSHA256: String,
        analyzerID: String,
        kind: String
    ) throws -> StoredDocumentAnalysis? {
        let statement = try prepare(
            """
            SELECT model_digest, analyzer_version, payload_json, created_at
            FROM analyses
            WHERE document_sha256 = ? AND analyzer_id = ? AND analysis_kind = ?
            ORDER BY created_at DESC LIMIT 1
            """
        )
        defer { sqlite3_finalize(statement) }
        for (offset, value) in [documentSHA256, analyzerID, kind].enumerated() {
            try bind(.text(value), to: statement, index: Int32(offset + 1))
        }
        guard try step(statement) == SQLITE_ROW,
              let modelDigest = sqlite3_column_text(statement, 0),
              let analyzerVersion = sqlite3_column_text(statement, 1),
              let payload = sqlite3_column_text(statement, 2)
        else { return nil }
        return StoredDocumentAnalysis(
            key: DocumentAnalysisKey(
                documentSHA256: documentSHA256,
                modelDigest: String(cString: modelDigest),
                analyzerID: analyzerID,
                analyzerVersion: String(cString: analyzerVersion),
                kind: kind
            ),
            payloadJSON: String(cString: payload),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
        )
    }

    public func saveAnalysis(_ analysis: StoredDocumentAnalysis) throws {
        try execute(
            """
            INSERT INTO analyses(
                document_sha256, model_digest, analyzer_id, analyzer_version,
                analysis_kind, payload_json, created_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(document_sha256, model_digest, analyzer_id, analyzer_version, analysis_kind)
            DO UPDATE SET payload_json = excluded.payload_json, created_at = excluded.created_at
            """,
            bindings: [
                .text(analysis.key.documentSHA256),
                .text(analysis.key.modelDigest),
                .text(analysis.key.analyzerID),
                .text(analysis.key.analyzerVersion),
                .text(analysis.key.kind),
                .text(analysis.payloadJSON),
                .double(analysis.createdAt.timeIntervalSince1970)
            ]
        )
    }

    public func deleteDocument(id: UUID) throws {
        if let record = try document(id: id) {
            try transaction {
                try execute(
                    "DELETE FROM documents WHERE id = ?",
                    bindings: [.text(id.uuidString)]
                )
            }
        }
        try checkpointAndTruncateWAL()
    }

    public func quickCheck() throws -> Bool {
        try Self.quickCheck(database)
    }

    private static func quickCheck(_ database: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "PRAGMA quick_check",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw DocumentLibraryError.statement(
                String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(statement) }
        var sawRow = false
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW,
                  let value = sqlite3_column_text(statement, 0)
            else {
                throw DocumentLibraryError.execute(
                    String(cString: sqlite3_errmsg(database))
                )
            }
            sawRow = true
            if String(cString: value) != "ok" { return false }
        }
        return sawRow
    }

    public func close() {
        connection.close()
    }

    private static func configure(_ database: OpaquePointer) throws {
        for sql in [
            "PRAGMA foreign_keys = ON",
            "PRAGMA busy_timeout = 5000",
            "PRAGMA journal_mode = WAL",
            "PRAGMA synchronous = FULL",
            "PRAGMA secure_delete = ON"
        ] {
            try execute(sql, database: database)
        }
    }

    private static func migrate(_ database: OpaquePointer) throws {
        let version = try userVersion(database)
        guard version <= schemaVersion else {
            throw DocumentLibraryError.futureSchema(version)
        }
        if version == 0 {
            try execute("BEGIN IMMEDIATE", database: database)
            do {
                try execute(
                    """
            CREATE TABLE IF NOT EXISTS documents(
                id TEXT PRIMARY KEY,
                content_sha256 TEXT NOT NULL UNIQUE,
                reference_json TEXT NOT NULL,
                blob_relative_path TEXT NOT NULL UNIQUE,
                imported_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS document_names(
                document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                display_name TEXT NOT NULL,
                imported_at REAL NOT NULL,
                UNIQUE(document_id, display_name)
            );
            CREATE TABLE IF NOT EXISTS chunks(
                document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                ordinal INTEGER NOT NULL,
                locator INTEGER NOT NULL,
                text TEXT NOT NULL,
                text_sha256 TEXT NOT NULL,
                PRIMARY KEY(document_id, ordinal)
            );
            CREATE TABLE IF NOT EXISTS analyses(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                document_sha256 TEXT NOT NULL,
                model_digest TEXT NOT NULL,
                analyzer_id TEXT NOT NULL,
                analyzer_version TEXT NOT NULL,
                analysis_kind TEXT NOT NULL,
                payload_json TEXT NOT NULL,
                created_at REAL NOT NULL,
                FOREIGN KEY(document_sha256) REFERENCES documents(content_sha256) ON DELETE CASCADE,
                UNIQUE(document_sha256, model_digest, analyzer_id, analyzer_version, analysis_kind)
            );
            PRAGMA user_version = 2;
            """,
                    database: database
                )
                try execute("COMMIT", database: database)
            } catch {
                try? execute("ROLLBACK", database: database)
                throw error
            }
            return
        }
        if version == 1 {
            try execute("BEGIN IMMEDIATE", database: database)
            do {
                try execute(
                    """
                    CREATE TABLE analyses_v2(
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        document_sha256 TEXT NOT NULL,
                        model_digest TEXT NOT NULL,
                        analyzer_id TEXT NOT NULL,
                        analyzer_version TEXT NOT NULL,
                        analysis_kind TEXT NOT NULL,
                        payload_json TEXT NOT NULL,
                        created_at REAL NOT NULL,
                        FOREIGN KEY(document_sha256) REFERENCES documents(content_sha256) ON DELETE CASCADE,
                        UNIQUE(document_sha256, model_digest, analyzer_id, analyzer_version, analysis_kind)
                    );
                    INSERT INTO analyses_v2(
                        document_sha256, model_digest, analyzer_id, analyzer_version,
                        analysis_kind, payload_json, created_at
                    )
                    SELECT a.document_sha256, a.model_digest, a.analyzer_id,
                           a.analyzer_version, a.analysis_kind, a.payload_json,
                           a.created_at
                    FROM analyses a
                    INNER JOIN documents d ON d.content_sha256 = a.document_sha256;
                    DROP TABLE analyses;
                    ALTER TABLE analyses_v2 RENAME TO analyses;
                    PRAGMA user_version = 2;
                    """,
                    database: database
                )
                try execute("COMMIT", database: database)
            } catch {
                try? execute("ROLLBACK", database: database)
                throw error
            }
        }
    }

    private func checkpointAndTruncateWAL() throws {
        var logFrames: Int32 = 0
        var checkpointedFrames: Int32 = 0
        let result = sqlite3_wal_checkpoint_v2(
            database,
            nil,
            SQLITE_CHECKPOINT_TRUNCATE,
            &logFrames,
            &checkpointedFrames
        )
        if result == SQLITE_BUSY || checkpointedFrames < logFrames {
            throw DocumentLibraryError.checkpointBusy
        }
        guard result == SQLITE_OK else {
            throw DocumentLibraryError.execute(
                String(cString: sqlite3_errmsg(database))
            )
        }
    }

    private func replaceChunksWithinTransaction(
        _ documentID: UUID,
        chunks: [PDFTextChunk]
    ) throws {
        try execute(
            "DELETE FROM chunks WHERE document_id = ?",
            bindings: [.text(documentID.uuidString)]
        )
        for (ordinal, chunk) in chunks.enumerated() {
            try execute(
                "INSERT INTO chunks(document_id, ordinal, locator, text, text_sha256) VALUES(?, ?, ?, ?, ?)",
                bindings: [
                    .text(documentID.uuidString),
                    .integer(Int64(ordinal)),
                    .integer(Int64(chunk.page)),
                    .text(chunk.text),
                    .text(Self.textDigest(chunk.text))
                ]
            )
        }
    }

    private func rememberName(_ name: String, for documentID: UUID) throws {
        try execute(
            "INSERT OR IGNORE INTO document_names(document_id, display_name, imported_at) VALUES(?, ?, ?)",
            bindings: [
                .text(documentID.uuidString),
                .text(name),
                .double(Date().timeIntervalSince1970)
            ]
        )
    }

    private func queryDocument(
        sql: String,
        value: String
    ) throws -> DocumentLibraryRecord? {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(.text(value), to: statement, index: 1)
        guard try step(statement) == SQLITE_ROW else { return nil }
        return try decodeRecord(statement)
    }

    private func decodeRecord(_ statement: OpaquePointer?) throws -> DocumentLibraryRecord {
        guard let jsonPointer = sqlite3_column_text(statement, 0) else {
            throw DocumentLibraryError.corrupt
        }
        let data = Data(String(cString: jsonPointer).utf8)
        let decodedReference = try decoder.decode(AttachmentReference.self, from: data)
        let displayName = sqlite3_column_count(statement) > 3
            ? sqlite3_column_text(statement, 3).map { String(cString: $0) }
                ?? decodedReference.displayName
            : decodedReference.displayName
        let reference = AttachmentReference(
            id: decodedReference.id,
            displayName: displayName,
            kind: decodedReference.kind,
            contentTypeIdentifier: decodedReference.contentTypeIdentifier,
            byteCount: decodedReference.byteCount,
            sha256: decodedReference.sha256,
            state: decodedReference.state,
            artifact: decodedReference.artifact,
            issue: decodedReference.issue
        )
        return DocumentLibraryRecord(
            reference: reference,
            importedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            blobRelativePath: sqlite3_column_text(statement, 2).map {
                String(cString: $0)
            } ?? ""
        )
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DocumentLibraryError.statement(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    private func execute(
        _ sql: String,
        bindings: [SQLiteBinding] = []
    ) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (offset, value) in bindings.enumerated() {
            try bind(value, to: statement, index: Int32(offset + 1))
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            let message = String(cString: sqlite3_errmsg(database))
            throw DocumentLibraryError.execute(message)
        }
    }

    private func executeReturningChanges(
        _ sql: String,
        bindings: [SQLiteBinding] = []
    ) throws -> Int {
        try execute(sql, bindings: bindings)
        return Int(sqlite3_changes(database))
    }

    private func step(_ statement: OpaquePointer?) throws -> Int32 {
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else {
            throw DocumentLibraryError.execute(
                String(cString: sqlite3_errmsg(database))
            )
        }
        return result
    }

    private func bind(
        _ binding: SQLiteBinding,
        to statement: OpaquePointer?,
        index: Int32
    ) throws {
        let result: Int32
        switch binding {
        case .text(let value):
            result = sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
        case .integer(let value):
            result = sqlite3_bind_int64(statement, index, value)
        case .double(let value):
            result = sqlite3_bind_double(statement, index, value)
        }
        guard result == SQLITE_OK else {
            throw DocumentLibraryError.execute("Could not bind a database value.")
        }
    }

    private static func execute(
        _ sql: String,
        database: OpaquePointer
    ) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw DocumentLibraryError.execute(message)
        }
    }

    private static func userVersion(_ database: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "PRAGMA user_version",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw DocumentLibraryError.statement(
                String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DocumentLibraryError.corrupt
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private static func escapeLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func textDigest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private final class SQLiteConnection: @unchecked Sendable {
    let handle: OpaquePointer
    private let lock = NSLock()
    private var isClosed = false

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        close()
    }

    func close() {
        lock.withLock {
            guard !isClosed else { return }
            sqlite3_close_v2(handle)
            isClosed = true
        }
    }
}

private enum SQLiteBinding {
    case text(String)
    case integer(Int64)
    case double(Double)
}

private let SQLITE_TRANSIENT = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)