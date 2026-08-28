import Foundation

struct LocalChatStores: Sendable {
    let sessions: SessionStore
    let memories: MemoryStore
    let logger: EventLogger
    let attachments: AttachmentStore

    init(root: URL? = nil) throws {
        if let root {
            sessions = try SessionStore(
                directory: root.appendingPathComponent("Sessions", isDirectory: true)
            )
            memories = try MemoryStore(
                directory: root.appendingPathComponent("Memories", isDirectory: true)
            )
            logger = try EventLogger(
                directory: root.appendingPathComponent("Logs", isDirectory: true)
            )
            attachments = try AttachmentStore(
                directory: root.appendingPathComponent("Attachments", isDirectory: true)
            )
        } else {
            sessions = try SessionStore()
            memories = try MemoryStore()
            logger = try EventLogger()
            attachments = try AttachmentStore()
        }
    }
}

public enum LocalChatPaths {
    public static func applicationSupportRoot(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("PrivateAI", isDirectory: true)
    }
}

public enum SessionDeletionResult: Sendable {
    case deleted
    case pending(String)
}

public actor SessionStore {
    private let directory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let deletedDirectory: URL
    private var latestRevisionBySession: [UUID: UInt64] = [:]
    private var deletedSessionIDs: Set<UUID> = []

    public init(directory: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        self.directory = try directory
            ?? LocalChatPaths.applicationSupportRoot(fileManager: fileManager)
                .appendingPathComponent("Sessions", isDirectory: true)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        try fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
        self.deletedDirectory = self.directory.appendingPathComponent(
            "Deleted",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: self.deletedDirectory,
            withIntermediateDirectories: true
        )
    }

    public func load() throws -> [ChatSession] {
        try reconcileDeletions()
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return try urls
            .filter { $0.pathExtension == "json" }
            .map { url in
                let data = try Data(contentsOf: url)
                return try decoder.decode(ChatSession.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func save(
        _ session: ChatSession,
        revision: UInt64? = nil
    ) throws {
        guard !deletedSessionIDs.contains(session.id) else { return }
        if let revision,
           revision < (latestRevisionBySession[session.id] ?? 0) {
            return
        }
        let data = try encoder.encode(session)
        try data.write(to: url(for: session.id), options: .atomic)
        if let revision {
            latestRevisionBySession[session.id] = revision
        }
    }

    @discardableResult
    public func delete(
        id: UUID,
        revision: UInt64? = nil
    ) throws -> SessionDeletionResult {
        let marker = deletedDirectory.appendingPathComponent(id.uuidString)
        if !fileManager.fileExists(atPath: marker.path) {
            try Data().write(to: marker, options: .atomic)
        }
        deletedSessionIDs.insert(id)
        if let revision {
            latestRevisionBySession[id] = max(
                latestRevisionBySession[id] ?? 0,
                revision
            )
        }
        do {
            try completeDeletion(id: id, marker: marker)
            return .deleted
        } catch {
            return .pending(error.localizedDescription)
        }
    }

    private func reconcileDeletions() throws {
        let markers = try fileManager.contentsOfDirectory(
            at: deletedDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for marker in markers {
            guard let id = UUID(uuidString: marker.lastPathComponent) else {
                continue
            }
            deletedSessionIDs.insert(id)
            try completeDeletion(id: id, marker: marker)
        }
    }

    private func completeDeletion(id: UUID, marker: URL) throws {
        let sessionURL = url(for: id)
        if fileManager.fileExists(atPath: sessionURL.path) {
            try fileManager.removeItem(at: sessionURL)
        }
        if fileManager.fileExists(atPath: marker.path) {
            try fileManager.removeItem(at: marker)
        }
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }
}

public actor MemoryStore {
    public static let defaultMaximumRecords = 6
    public static let defaultMaximumCharacters = 1_200

    private let directory: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(directory: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        self.directory = try directory
            ?? LocalChatPaths.applicationSupportRoot(fileManager: fileManager)
                .appendingPathComponent("Memories", isDirectory: true)
        try fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    public func load() throws -> [MemoryRecord] {
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return try urls
            .filter { $0.pathExtension == "json" }
            .map { url in
                let data = try Data(contentsOf: url)
                return try decoder.decode(MemoryRecord.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func save(_ record: MemoryRecord) throws {
        let trimmed = record.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normalized = MemoryRecord(
            id: record.id,
            createdAt: record.createdAt,
            sessionID: record.sessionID,
            summary: String(trimmed.prefix(500))
        )
        try encoder.encode(normalized).write(
            to: directory
                .appendingPathComponent(record.id.uuidString)
                .appendingPathExtension("json"),
            options: .atomic
        )
    }

    public func delete(id: UUID) throws {
        let url = directory
            .appendingPathComponent(id.uuidString)
            .appendingPathExtension("json")
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    public func relevant(
        to query: String,
        maximumRecords: Int = MemoryStore.defaultMaximumRecords,
        maximumCharacters: Int = MemoryStore.defaultMaximumCharacters
    ) throws -> [MemoryRecord] {
        Self.boundedRelevant(
            try load(),
            query: query,
            maximumRecords: maximumRecords,
            maximumCharacters: maximumCharacters
        )
    }

    public static func boundedRelevant(
        _ records: [MemoryRecord],
        query: String,
        maximumRecords: Int = defaultMaximumRecords,
        maximumCharacters: Int = defaultMaximumCharacters
    ) -> [MemoryRecord] {
        guard maximumRecords > 0, maximumCharacters > 0 else { return [] }
        let queryTerms = terms(in: query)
        let ranked = records.enumerated().sorted { lhs, rhs in
            let leftOverlap = terms(in: lhs.element.summary).intersection(queryTerms).count
            let rightOverlap = terms(in: rhs.element.summary).intersection(queryTerms).count
            if leftOverlap != rightOverlap { return leftOverlap > rightOverlap }
            if lhs.element.createdAt != rhs.element.createdAt {
                return lhs.element.createdAt > rhs.element.createdAt
            }
            return lhs.offset < rhs.offset
        }

        var remaining = maximumCharacters
        var selected: [MemoryRecord] = []
        for (_, record) in ranked where selected.count < maximumRecords {
            let summary = record.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty, summary.count <= remaining else { continue }
            selected.append(record)
            remaining -= summary.count
        }
        return selected
    }

    private static func terms(in text: String) -> Set<String> {
        Set(
            text.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .filter { $0.count > 2 }
                .map(String.init)
        )
    }
}

public actor EventLogger {
    private let directory: URL
    private let fileURL: URL
    private let encoder = JSONEncoder()

    public init(directory: URL? = nil, fileManager: FileManager = .default) throws {
        self.directory = try directory
            ?? LocalChatPaths.applicationSupportRoot(fileManager: fileManager)
                .appendingPathComponent("Logs", isDirectory: true)
        try fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        self.fileURL = self.directory
            .appendingPathComponent("local-chat-\(formatter.string(from: Date()))")
            .appendingPathExtension("jsonl")
    }

    public func log(
        _ event: String,
        sessionID: UUID? = nil,
        model: String? = nil,
        fields: [String: String] = [:]
    ) {
        var object: [String: String] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "event": event
        ]
        if let sessionID { object["session_id"] = sessionID.uuidString }
        if let model { object["model"] = model }
        fields.forEach { object[$0.key] = String($0.value.prefix(500)) }
        guard let data = try? encoder.encode(object) else { return }
        var line = data
        line.append(0x0A)

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: line)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            return
        }
    }

    public func logsDirectory() -> URL {
        directory
    }
}
