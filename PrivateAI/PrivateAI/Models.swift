import Foundation

public enum ChatRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

public enum ToolStatus: String, Codable, Sendable {
    case running
    case success
    case failure
}

public enum AssistantResponseState: String, Codable, Hashable, Sendable {
    case streaming
    case complete
    case stopped
    case failed
}

public enum SessionForkReason: String, Codable, Hashable, Sendable {
    case retry
    case regenerate
    case editAndResend
}

public struct SessionFork: Codable, Hashable, Sendable {
    public let parentSessionID: UUID
    public let parentTitle: String
    public let sourceMessageID: UUID
    public let reason: SessionForkReason

    public init(
        parentSessionID: UUID,
        parentTitle: String,
        sourceMessageID: UUID,
        reason: SessionForkReason
    ) {
        self.parentSessionID = parentSessionID
        self.parentTitle = parentTitle
        self.sourceMessageID = sourceMessageID
        self.reason = reason
    }
}

public struct EditAndResendSource: Equatable, Sendable {
    public let sessionID: UUID
    public let messageID: UUID
    public let parentTitle: String
    public let originalContent: String
    public let previousDraft: String
    public let attachments: [AttachmentReference]
    public let previousAttachments: [AttachmentReference]

    public init(
        sessionID: UUID,
        messageID: UUID,
        parentTitle: String,
        originalContent: String,
        previousDraft: String,
        attachments: [AttachmentReference] = [],
        previousAttachments: [AttachmentReference] = []
    ) {
        self.sessionID = sessionID
        self.messageID = messageID
        self.parentTitle = parentTitle
        self.originalContent = originalContent
        self.previousDraft = previousDraft
        self.attachments = attachments
        self.previousAttachments = previousAttachments
    }
}

public struct LocalFileAuthorizationRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let originalPrompt: String
    public let typedPaths: [String]

    public init(
        id: UUID = UUID(),
        originalPrompt: String,
        typedPaths: [String]
    ) {
        self.id = id
        self.originalPrompt = originalPrompt
        self.typedPaths = typedPaths
    }

    public var displayNames: [String] {
        typedPaths.map { URL(fileURLWithPath: $0).lastPathComponent }
    }
}

public enum AttachmentKind: String, Codable, Hashable, Sendable {
    case image
    case pdf
    case text
}

public enum AttachmentState: String, Codable, Hashable, Sendable {
    case ready
    case advancedParserRequired
    case failed
}

public struct AttachmentIssue: Codable, Hashable, Sendable {
    public enum Code: String, Codable, Hashable, Sendable {
        case unsupportedType
        case accessDenied
        case copyFailed
        case corruptImage
        case encryptedPDF
        case noExtractableText
        case cancelled
        case deletedFromLibrary
    }

    public let code: Code
    public let message: String
    public let retryable: Bool

    public init(code: Code, message: String, retryable: Bool = false) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }
}

public struct AttachmentArtifactReceipt: Codable, Hashable, Sendable {
    public let parserID: String
    public let parserVersion: String
    public let pageCount: Int
    public let chunkCount: Int
    public let characterCount: Int

    public init(
        parserID: String,
        parserVersion: String,
        pageCount: Int,
        chunkCount: Int,
        characterCount: Int
    ) {
        self.parserID = parserID
        self.parserVersion = parserVersion
        self.pageCount = pageCount
        self.chunkCount = chunkCount
        self.characterCount = characterCount
    }
}

public struct AttachmentReference: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let displayName: String
    public let kind: AttachmentKind
    public let contentTypeIdentifier: String
    public let byteCount: Int64
    public let sha256: String
    public let state: AttachmentState
    public let artifact: AttachmentArtifactReceipt?
    public let issue: AttachmentIssue?

    public init(
        id: UUID = UUID(),
        displayName: String,
        kind: AttachmentKind,
        contentTypeIdentifier: String,
        byteCount: Int64,
        sha256: String,
        state: AttachmentState,
        artifact: AttachmentArtifactReceipt? = nil,
        issue: AttachmentIssue? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.contentTypeIdentifier = contentTypeIdentifier
        self.byteCount = byteCount
        self.sha256 = sha256
        self.state = state
        self.artifact = artifact
        self.issue = issue
    }
}

public struct AssistantResponseIssue: Codable, Hashable, Sendable {
    public enum Code: String, Codable, Hashable, Sendable {
        case timeout
        case transport
        case invalidStream
        case contextOverflow
        case interruptedByRestart
        case unknown
    }

    public let code: Code
    public let message: String
    public let retryable: Bool

    public init(code: Code, message: String, retryable: Bool = true) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }
}

public struct ContextReceipt: Codable, Hashable, Sendable {
    public let contextWindow: Int
    public let outputReserve: Int
    public let estimatedPromptTokens: Int
    public var actualPromptTokens: Int?
    public let fullTurns: Int
    public let compactedTurns: Int
    public let omittedTurns: Int
    public let memoryRecords: Int
    public let toolPairs: Int
    public let attachmentTokens: Int?
    public let attachmentChunks: Int?
    public let documentProfiles: Int?
    public let visionImages: Int?

    public init(
        contextWindow: Int,
        outputReserve: Int,
        estimatedPromptTokens: Int,
        actualPromptTokens: Int? = nil,
        fullTurns: Int,
        compactedTurns: Int,
        omittedTurns: Int,
        memoryRecords: Int,
        toolPairs: Int,
        attachmentTokens: Int? = nil,
        attachmentChunks: Int? = nil,
        documentProfiles: Int? = nil,
        visionImages: Int? = nil
    ) {
        self.contextWindow = contextWindow
        self.outputReserve = outputReserve
        self.estimatedPromptTokens = estimatedPromptTokens
        self.actualPromptTokens = actualPromptTokens
        self.fullTurns = fullTurns
        self.compactedTurns = compactedTurns
        self.omittedTurns = omittedTurns
        self.memoryRecords = memoryRecords
        self.toolPairs = toolPairs
        self.attachmentTokens = attachmentTokens
        self.attachmentChunks = attachmentChunks
        self.documentProfiles = documentProfiles
        self.visionImages = visionImages
    }
}

public enum OllamaReadiness: Equatable, Sendable {
    case checking
    case notInstalled
    case serviceUnavailable
    case updateRequired(installedVersion: String)
    case modelMissing(availableDiskBytes: Int64?)
    case ready(version: String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

public struct SourceLink: Codable, Hashable, Identifiable, Sendable {
    public var id: String { url }
    public let title: String
    public let url: String

    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}

public struct ToolActivity: Codable, Hashable, Sendable {
    public let name: String
    public let inputSummary: String
    public let reason: String?
    public var status: ToolStatus
    public var detail: String
    public var sources: [SourceLink]
    public var invocation: ToolInvocation?

    public init(
        name: String,
        inputSummary: String,
        reason: String? = nil,
        status: ToolStatus = .running,
        detail: String = "",
        sources: [SourceLink] = [],
        invocation: ToolInvocation? = nil
    ) {
        self.name = name
        self.inputSummary = inputSummary
        self.reason = reason
        self.status = status
        self.detail = detail
        self.sources = sources
        self.invocation = invocation
    }

    public var displayName: String {
        switch name {
        case "web_search": String(localized: "Web search")
        case "fetch_url", "browser_snapshot", "browser_extract": String(localized: "Read webpage")
        case "local_search": String(localized: "Nearby search")
        case "local_context": String(localized: "Mac context")
        case "code_interpreter": String(localized: "Local calculation")
        default: name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    public var runningLabel: String {
        switch name {
        case "web_search": String(localized: "Searching the web")
        case "fetch_url", "browser_snapshot", "browser_extract": String(localized: "Reading a webpage")
        case "local_search": String(localized: "Searching nearby places")
        case "local_context": String(localized: "Checking this Mac")
        case "code_interpreter": String(localized: "Calculating locally")
        default: String(localized: "Using \(displayName)")
        }
    }
}

public struct ChatMessage: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var role: ChatRole
    public var content: String
    public var thinking: String?
    public let timestamp: Date
    public var tool: ToolActivity?
    public var responseState: AssistantResponseState?
    public var toolCalls: [ToolInvocation]?
    public var responseIssue: AssistantResponseIssue?
    public var contextReceipt: ContextReceipt?
    public var attachments: [AttachmentReference]?

    public init(
        id: UUID = UUID(),
        role: ChatRole,
        content: String,
        thinking: String? = nil,
        timestamp: Date = Date(),
        tool: ToolActivity? = nil,
        responseState: AssistantResponseState? = nil,
        toolCalls: [ToolInvocation]? = nil,
        responseIssue: AssistantResponseIssue? = nil,
        contextReceipt: ContextReceipt? = nil,
        attachments: [AttachmentReference]? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.thinking = thinking
        self.timestamp = timestamp
        self.tool = tool
        self.responseState = responseState
        self.toolCalls = toolCalls
        self.responseIssue = responseIssue
        self.contextReceipt = contextReceipt
        self.attachments = attachments
    }
}

public struct ChatSession: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public let createdAt: Date
    public var updatedAt: Date
    public var messages: [ChatMessage]
    public var fork: SessionFork?

    public init(
        id: UUID = UUID(),
        title: String = String(localized: "New chat"),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messages: [ChatMessage] = [],
        fork: SessionFork? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.fork = fork
    }

    public static func title(from prompt: String) -> String {
        let singleLine = prompt
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !singleLine.isEmpty else { return String(localized: "New chat") }
        return String(singleLine.prefix(64))
    }
}

public enum SessionListPresentation {
    public static func updatedTimestamp(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        localizesRelativeTerms: Bool = false
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        let startOfToday = calendar.startOfDay(for: now)
        if let startOfYesterday = calendar.date(
            byAdding: .day,
            value: -1,
            to: startOfToday
        ), calendar.isDate(date, inSameDayAs: startOfYesterday) {
            return localizesRelativeTerms
                ? String(localized: "Yesterday")
                : "Yesterday"
        }
        let dateYear = calendar.component(.year, from: date)
        let currentYear = calendar.component(.year, from: now)
        if dateYear == currentYear {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.year().month(.abbreviated).day())
    }
}

public struct MemoryRecord: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let sessionID: UUID
    public let summary: String

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        sessionID: UUID,
        summary: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.sessionID = sessionID
        self.summary = summary
    }
}

public struct PerformanceStats: Equatable, Sendable {
    public var model = ""
    public var thinkingEnabled = false
    public var ttftSeconds: Double?
    public var tokensPerSecond = 0.0
    public var promptTokens = 0
    public var outputTokens = 0
    public var contextEstimate = 0
    public var contextWindow = ContextPlanner.defaultContextWindow
    public var compactedTurns = 0
    public var omittedTurns = 0
}

public struct LiveGenerationMeter: Equatable, Sendable {
    public private(set) var completedTokens = 0
    private var currentCharacters = 0
    private var roundStartedAt: Date?

    public init() {}

    public mutating func beginRound() {
        currentCharacters = 0
        roundStartedAt = nil
    }

    public mutating func ingest(
        characterCount: Int,
        at now: Date = Date()
    ) -> (totalTokens: Int, tokensPerSecond: Double) {
        guard characterCount > 0 else {
            return (completedTokens, 0)
        }
        if roundStartedAt == nil {
            roundStartedAt = now
        }
        currentCharacters += characterCount
        let estimatedRoundTokens = max(
            Int(ceil(Double(currentCharacters) / 4.0)),
            1
        )
        let elapsed = max(
            now.timeIntervalSince(roundStartedAt ?? now),
            0.001
        )
        return (
            completedTokens + estimatedRoundTokens,
            Double(estimatedRoundTokens) / elapsed
        )
    }

    public mutating func finishRound(
        exactTokens: Int,
        evaluationDurationNanoseconds: UInt64
    ) -> (totalTokens: Int, tokensPerSecond: Double) {
        completedTokens += max(exactTokens, 0)
        currentCharacters = 0
        roundStartedAt = nil
        let speed = evaluationDurationNanoseconds > 0
            ? Double(max(exactTokens, 0))
                / (Double(evaluationDurationNanoseconds) / 1_000_000_000)
            : 0
        return (completedTokens, speed)
    }

}

public enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var integerValue: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public func jsonString() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct ToolInvocation: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let arguments: [String: JSONValue]

    public init(id: String = UUID().uuidString, name: String, arguments: [String: JSONValue]) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct ToolResult: Sendable {
    public let content: String
    public let summary: String
    public let sources: [SourceLink]
    public let groundedAnswer: String?

    public init(
        content: String,
        summary: String,
        sources: [SourceLink] = [],
        groundedAnswer: String? = nil
    ) {
        self.content = content
        self.summary = summary
        self.sources = sources
        self.groundedAnswer = groundedAnswer
    }
}
