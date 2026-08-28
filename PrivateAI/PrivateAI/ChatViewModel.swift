import AppKit
import Combine
import Foundation

public enum LocalChatNotifications {
    public static let newSession = Notification.Name("LocalChat.NewSession")
}

struct PendingAttachmentImport: Identifiable, Equatable, Sendable {
    let id: UUID
    let displayName: String
}

struct SessionSearchResult: Identifiable, Equatable, Sendable {
    let session: ChatSession
    let messageID: UUID?
    let snippet: String?

    var id: UUID { session.id }
}

private struct CachedMessageSearchText {
    let role: ChatRole
    let content: String
    let visibleText: String
    let searchableText: String
}

private struct GenerationConfiguration: Sendable {
    let modelName: String
    let modelDigest: String?
    let thinkingEnabled: Bool
}

private struct DocumentProfileWarmup: Sendable {
    let attachment: AttachmentReference
    let modelName: String
    let modelDigest: String

    var key: String {
        "\(attachment.sha256)|\(modelName)|\(modelDigest)"
    }
}

@MainActor
public final class ChatViewModel: ObservableObject {
    @Published public private(set) var sessions: [ChatSession] = []
    @Published public var selectedSessionID: UUID? {
        didSet {
            if selectedSessionID != oldValue {
                requestedScrollMessageID = nil
                requestedScrollRequestID = nil
            }
        }
    }
    @Published public var composerText = ""
    @Published public private(set) var composerFocusRequestID: UUID?
    @Published public private(set) var models: [OllamaModel] = []
    @Published public var selectedModel: String {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "localChat.model") }
    }
    @Published public var baseURL: String
    @Published public var thinkingEnabled: Bool {
        didSet { UserDefaults.standard.set(thinkingEnabled, forKey: "localChat.thinking") }
    }
    @Published public private(set) var isStreaming = false
    @Published public private(set) var statusMessage = ""
    @Published public private(set) var ollamaReadiness: OllamaReadiness = .checking
    @Published public private(set) var performance = PerformanceStats()
    @Published public private(set) var memories: [MemoryRecord] = []
    @Published public private(set) var transcriptRevision = 0
    @Published public private(set) var sessionErrorMessage: String?
    @Published public private(set) var requestedScrollMessageID: UUID?
    @Published public private(set) var requestedScrollRequestID: UUID?
    @Published public private(set) var editAndResendSource: EditAndResendSource?
    @Published public var sessionSearchText = ""
    @Published public private(set) var draftAttachments: [AttachmentReference] = []
    @Published public private(set) var isImportingAttachments = false
    @Published private(set) var pendingAttachmentImports: [PendingAttachmentImport] = []
    @Published public private(set) var attachmentErrorMessage: String?
    @Published public private(set) var pendingLocalFileAuthorization: LocalFileAuthorizationRequest?
    @Published public private(set) var libraryDocuments: [DocumentLibraryRecord] = []
    @Published public private(set) var libraryProfiles: [UUID: DocumentProfile] = [:]
    @Published public private(set) var isLoadingLibrary = false
    @Published public private(set) var libraryErrorMessage: String?

    private let sessionStore: SessionStore
    private let memoryStore: MemoryStore
    private let logger: EventLogger
    private let ollamaClient: OllamaClient
    private let profileOllamaClient: OllamaClient
    private let memoryOllamaClient: OllamaClient
    private let webTools: WebToolExecutor
    private let attachmentStore: AttachmentStore
    private let documentAnalyzer: DocumentAnalyzer
    private let memoryProcessingEnabled: Bool
    private let ollamaApplicationURL: () -> URL?
    private let availableDiskBytes: () -> Int64?
    private var responseTask: Task<Void, Never>?
    private var memoryTask: Task<Void, Never>?
    private var attachmentImportTask: (id: UUID, task: Task<Void, Never>)?
    private var pendingAttachmentImportCount = 0
    private var attachmentImportIssues: [String] = []
    private var documentProfileWarmupQueue: [DocumentProfileWarmup] = []
    private var documentProfileWarmupKeys: Set<String> = []
    private var activeDocumentProfileWarmup: DocumentProfileWarmup?
    private var documentProfileTask: Task<Void, Never>?
    private var pendingMemorySessionIDs: [UUID] = []
    private var activeGenerationID: UUID?
    private var activeGenerationConfiguration: GenerationConfiguration?
    private var activeGenerationSessionID: UUID?
    private var activeAssistantMessageID: UUID?
    private var activeToolMessageID: UUID?
    private var hasBootstrapped = false
    private var liveGenerationMeter = LiveGenerationMeter()
    private var lastCheckpointCharacters = 0
    private var persistenceRevision: UInt64 = 0
    private var isShuttingDown = false
    private var messageSearchTextCache: [UUID: CachedMessageSearchText] = [:]
    private var streamedRawContentByMessageID: [UUID: String] = [:]

    init(
        baseURL: String,
        selectedModel: String,
        thinkingEnabled: Bool,
        sessionStore: SessionStore,
        memoryStore: MemoryStore,
        logger: EventLogger,
        ollamaClient: OllamaClient,
        profileOllamaClient: OllamaClient? = nil,
        memoryOllamaClient: OllamaClient? = nil,
        webTools: WebToolExecutor = WebToolExecutor(),
        attachmentStore: AttachmentStore,
        memoryProcessingEnabled: Bool = true,
        ollamaApplicationURL: (() -> URL?)? = nil,
        availableDiskBytes: (() -> Int64?)? = nil
    ) {
        self.baseURL = baseURL
        self.selectedModel = selectedModel
        self.thinkingEnabled = thinkingEnabled
        self.sessionStore = sessionStore
        self.memoryStore = memoryStore
        self.logger = logger
        self.ollamaClient = ollamaClient
        self.profileOllamaClient = profileOllamaClient ?? ollamaClient
        self.memoryOllamaClient = memoryOllamaClient ?? ollamaClient
        self.webTools = webTools
        self.attachmentStore = attachmentStore
        self.documentAnalyzer = DocumentAnalyzer(
            attachmentStore: attachmentStore,
            ollamaClient: self.profileOllamaClient
        )
        self.memoryProcessingEnabled = memoryProcessingEnabled
        self.ollamaApplicationURL = ollamaApplicationURL ?? {
            NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.electron.ollama"
            )
        }
        self.availableDiskBytes = availableDiskBytes ?? {
            let values = try? FileManager.default.homeDirectoryForCurrentUser
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values?.volumeAvailableCapacityForImportantUsage
        }
    }

    deinit {
        responseTask?.cancel()
        memoryTask?.cancel()
        attachmentImportTask?.task.cancel()
        documentProfileTask?.cancel()
    }

    public func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        documentProfileWarmupQueue = []
        documentProfileWarmupKeys = []
        pendingMemorySessionIDs = []
        let tasks = [
            responseTask,
            memoryTask,
            attachmentImportTask?.task,
            documentProfileTask
        ].compactMap { $0 }
        tasks.forEach { $0.cancel() }
        await ollamaClient.cancel()
        await profileOllamaClient.cancel()
        await memoryOllamaClient.cancel()
        for task in tasks {
            await task.value
        }
    }

    public var currentSession: ChatSession? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    public var visibleSessions: [ChatSession] {
        sessionSearchResults.map(\.session)
    }

    var sessionSearchResults: [SessionSearchResult] {
        let query = sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return sessions.map {
                SessionSearchResult(session: $0, messageID: nil, snippet: nil)
            }
        }
        let searchableQuery = Self.searchableText(query)
        guard !searchableQuery.isEmpty else { return [] }
        return sessions.compactMap { session in
            let matchingMessage = session.messages.reversed().first { message in
                guard message.role == .user || message.role == .assistant else {
                    return false
                }
                guard message.responseState != .streaming else { return false }
                return searchText(for: message).searchableText.contains(
                    searchableQuery
                )
            }
            let titleMatches = Self.searchableText(session.title)
                .contains(searchableQuery)
            guard titleMatches || matchingMessage != nil else { return nil }
            return SessionSearchResult(
                session: session,
                messageID: matchingMessage?.id,
                snippet: matchingMessage.map {
                    Self.searchSnippet(
                        content: searchText(for: $0).visibleText,
                        query: searchableQuery,
                        role: $0.role
                    )
                }
            )
        }
    }

    func openSearchResult(_ result: SessionSearchResult) {
        guard !isStreaming else { return }
        selectedSessionID = result.session.id
        requestedScrollMessageID = result.messageID
        requestedScrollRequestID = result.messageID == nil ? nil : UUID()
    }

    private static func searchableText(_ input: String) -> String {
        input
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
    }

    private func searchText(for message: ChatMessage) -> CachedMessageSearchText {
        if let cached = messageSearchTextCache[message.id],
           cached.role == message.role,
           cached.content == message.content {
            return cached
        }
        let visibleText: String
        if message.role == .user {
            visibleText = Self.normalizedWhitespace(message.content)
        } else if let markdown = try? AttributedString(
            markdown: Self.removingMathSource(from: message.content)
        ) {
            visibleText = Self.normalizedWhitespace(String(markdown.characters))
        } else {
            visibleText = ""
        }
        let cached = CachedMessageSearchText(
            role: message.role,
            content: message.content,
            visibleText: visibleText,
            searchableText: Self.searchableText(visibleText)
        )
        messageSearchTextCache[message.id] = cached
        return cached
    }

    private static func normalizedWhitespace(_ input: String) -> String {
        input.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func removingMathSource(from input: String) -> String {
        var output = ""
        var index = input.startIndex
        while index < input.endIndex {
            guard input[index] == "$",
                  index == input.startIndex
                    || input[input.index(before: index)] != "\\"
            else {
                output.append(input[index])
                index = input.index(after: index)
                continue
            }
            let next = input.index(after: index)
            let delimiter = next < input.endIndex && input[next] == "$"
                ? "$$"
                : "$"
            let contentStart = input.index(
                index,
                offsetBy: delimiter.count
            )
            guard let closing = input.range(
                of: delimiter,
                range: contentStart..<input.endIndex
            ) else {
                output.append(contentsOf: delimiter)
                index = contentStart
                continue
            }
            output.append(" ")
            index = closing.upperBound
        }
        return output
    }

    private static func searchSnippet(
        content: String,
        query: String,
        role: ChatRole
    ) -> String {
        let text = normalizedWhitespace(content)
        let options: String.CompareOptions = [
            .caseInsensitive,
            .diacriticInsensitive,
            .widthInsensitive
        ]
        let match = text.range(of: query, options: options)
        let center = match.map { text.distance(from: text.startIndex, to: $0.lowerBound) }
            ?? 0
        let maximumCharacters = min(max(140, query.count + 96), 280)
        let leadingCharacters = min(center, 48)
        let startOffset = max(center - leadingCharacters, 0)
        let start = text.index(text.startIndex, offsetBy: startOffset)
        let end = text.index(
            start,
            offsetBy: min(maximumCharacters, text.distance(from: start, to: text.endIndex))
        )
        let prefix = start == text.startIndex ? "" : "…"
        let suffix = end == text.endIndex ? "" : "…"
        let roleLabel = role == .user ? "You" : "PrivateAI"
        return "\(roleLabel): \(prefix)\(text[start..<end])\(suffix)"
    }

    public var currentAgentActivity: ToolActivity? {
        currentSession?.messages.reversed().compactMap(\.tool).first {
            $0.status == .running
        }
    }

    public var canSend: Bool {
        let hasPrompt = !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachments = !draftAttachments.isEmpty
        return !isStreaming
            && !isShuttingDown
            && !isImportingAttachments
            && models.contains(where: { $0.name == selectedModel })
            && ollamaReadiness.isReady
            && (hasPrompt || hasAttachments)
            && draftAttachments.count <= AttachmentStore.maximumAttachmentsPerChat
            && Set(draftAttachments.map(\.sha256)).count == draftAttachments.count
            && draftAttachments.allSatisfy { $0.state == .ready }
    }

    public func bootstrap() async throws {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        do {
            let recovery = Self.recoverInterruptedSessions(
                try await sessionStore.load()
            )
            sessions = recovery.sessions
            for sessionID in recovery.changedSessionIDs {
                if let session = sessions.first(where: { $0.id == sessionID }) {
                    try await sessionStore.save(
                        session,
                        revision: nextPersistenceRevision()
                    )
                }
            }
            if sessions.isEmpty {
                let session = ChatSession()
                sessions = [session]
                try await sessionStore.save(
                    session,
                    revision: nextPersistenceRevision()
                )
            }
            selectedSessionID = sessions.first?.id
            try await attachmentStore.reconcilePendingImports()
            try await reconcileDeletedDocumentReferences()
            memories = try await memoryStore.load()
        } catch {
            hasBootstrapped = false
            throw error
        }
        await refreshModels()
    }

    static func productionForLaunch() async throws -> ChatViewModel {
        let stores = try await Task.detached(priority: .userInitiated) {
            try LocalChatStores()
        }.value
        let defaults = UserDefaults.standard
        return ChatViewModel(
            baseURL: OllamaClient.localBaseURL.absoluteString,
            selectedModel: defaults.string(forKey: "localChat.model")
                ?? OllamaClient.recommendedModelName,
            thinkingEnabled: defaults.object(forKey: "localChat.thinking") as? Bool ?? false,
            sessionStore: stores.sessions,
            memoryStore: stores.memories,
            logger: stores.logger,
            ollamaClient: OllamaClient(),
            profileOllamaClient: OllamaClient(),
            memoryOllamaClient: OllamaClient(),
            webTools: WebToolExecutor(),
            attachmentStore: stores.attachments
        )
    }

    static func recoverInterruptedSessions(
        _ input: [ChatSession]
    ) -> (sessions: [ChatSession], changedSessionIDs: Set<UUID>) {
        var sessions = input
        var changed = Set<UUID>()
        for sessionIndex in sessions.indices {
            var didChange = false
            for messageIndex in sessions[sessionIndex].messages.indices {
                var message = sessions[sessionIndex].messages[messageIndex]
                if message.role == .assistant, message.responseState == .streaming {
                    if message.content.isEmpty {
                        message.content = "Response interrupted when PrivateAI closed."
                    }
                    message.responseState = .stopped
                    message.responseIssue = AssistantResponseIssue(
                        code: .interruptedByRestart,
                        message: "PrivateAI closed before this response completed."
                    )
                    didChange = true
                }
                if message.role == .tool, message.tool?.status == .running {
                    message.tool?.status = .failure
                    message.tool?.detail = "Tool interrupted when PrivateAI closed."
                    didChange = true
                }
                sessions[sessionIndex].messages[messageIndex] = message
            }

            if let last = sessions[sessionIndex].messages.last,
               last.role == .user {
                sessions[sessionIndex].messages.append(
                    ChatMessage(
                        role: .assistant,
                        content: "Response interrupted when PrivateAI closed.",
                        responseState: .stopped,
                        responseIssue: AssistantResponseIssue(
                            code: .interruptedByRestart,
                            message: "No completed response was saved for this message."
                        )
                    )
                )
                didChange = true
            }
            if didChange {
                sessions[sessionIndex].updatedAt = Date()
                changed.insert(sessions[sessionIndex].id)
            }
        }
        sessions.sort { $0.updatedAt > $1.updatedAt }
        return (sessions, changed)
    }

    private func reconcileDeletedDocumentReferences() async throws {
        let deletedIDs = try await attachmentStore.deletedDocumentIDs()
        guard !deletedIDs.isEmpty else { return }
        var changedSessionIDs: [UUID] = []
        for sessionIndex in sessions.indices {
            var changed = false
            for messageIndex in sessions[sessionIndex].messages.indices {
                guard var attachments = sessions[sessionIndex]
                    .messages[messageIndex].attachments
                else { continue }
                for attachmentIndex in attachments.indices
                where deletedIDs.contains(attachments[attachmentIndex].id)
                    && attachments[attachmentIndex].issue?.code != .deletedFromLibrary {
                    attachments[attachmentIndex] = Self.deletedReference(
                        from: attachments[attachmentIndex]
                    )
                    changed = true
                }
                sessions[sessionIndex].messages[messageIndex].attachments = attachments
            }
            if changed { changedSessionIDs.append(sessions[sessionIndex].id) }
        }
        for sessionID in changedSessionIDs {
            guard let session = sessions.first(where: { $0.id == sessionID }) else {
                continue
            }
            try await sessionStore.save(
                session,
                revision: nextPersistenceRevision()
            )
        }
        if !changedSessionIDs.isEmpty { transcriptRevision += 1 }
    }

    private static func deletedReference(
        from reference: AttachmentReference
    ) -> AttachmentReference {
        AttachmentReference(
            id: reference.id,
            displayName: reference.displayName,
            kind: reference.kind,
            contentTypeIdentifier: reference.contentTypeIdentifier,
            byteCount: reference.byteCount,
            sha256: reference.sha256,
            state: .failed,
            artifact: reference.artifact,
            issue: AttachmentIssue(
                code: .deletedFromLibrary,
                message: "Deleted from the local Document Library.",
                retryable: false
            )
        )
    }

    public func newSession() {
        guard !isStreaming else { return }
        let session = ChatSession()
        sessions.insert(session, at: 0)
        selectedSessionID = session.id
        composerFocusRequestID = UUID()
        transcriptRevision += 1
        persistSession(session.id)
        Task {
            await logger.log("session_created", sessionID: session.id)
        }
    }

    func acknowledgeComposerFocus(_ requestID: UUID) {
        guard composerFocusRequestID == requestID else { return }
        composerFocusRequestID = nil
    }

    public func deleteSession(_ id: UUID) async {
        guard !isStreaming else { return }
        guard let deletedSession = sessions.first(where: { $0.id == id }) else {
            return
        }
        sessionErrorMessage = nil
        let result: SessionDeletionResult
        do {
            result = try await sessionStore.delete(
                id: id,
                revision: nextPersistenceRevision()
            )
        } catch {
            sessionErrorMessage = "Chat deletion failed: \(error.localizedDescription)"
            await logger.log(
                "session_delete_error",
                sessionID: id,
                fields: ["error": error.localizedDescription]
            )
            return
        }

        sessions.removeAll { $0.id == id }
        for message in deletedSession.messages {
            messageSearchTextCache[message.id] = nil
        }
        if sessions.isEmpty {
            let session = ChatSession()
            sessions = [session]
            selectedSessionID = session.id
            persistSession(session.id)
        } else if selectedSessionID == id {
            selectedSessionID = sessions.first?.id
        }
        transcriptRevision += 1
        switch result {
        case .deleted:
            await logger.log("session_deleted", sessionID: id)
        case .pending(let message):
            sessionErrorMessage = "Chat deletion is pending local cleanup: \(message)"
            await logger.log(
                "session_delete_pending",
                sessionID: id,
                fields: ["error": message]
            )
        }
    }

    public func renameSession(_ id: UUID, to rawTitle: String) {
        let title = rawTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !title.isEmpty,
              let index = sessions.firstIndex(where: { $0.id == id })
        else { return }
        sessions[index].title = String(title.prefix(64))
        sessions[index].updatedAt = Date()
        sortSessionsKeepingSelection()
        transcriptRevision += 1
        persistSession(id)
        Task {
            await logger.log("session_renamed", sessionID: id)
        }
    }

    public func send() {
        let typedPrompt = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let typedPaths = ToolPolicy.localFilePaths(in: typedPrompt)
        if !typedPaths.isEmpty {
            pendingLocalFileAuthorization = LocalFileAuthorizationRequest(
                originalPrompt: typedPrompt,
                typedPaths: typedPaths
            )
            statusMessage = String(localized: "Choose the local file to grant read access")
            return
        }
        guard canSend else { return }
        let attachments = draftAttachments
        let configuration = GenerationConfiguration(
            modelName: selectedModel,
            modelDigest: activeModelDigest,
            thinkingEnabled: thinkingEnabled
        )
        let promptWithoutPaths = ToolPolicy.promptByRemovingLocalFilePaths(typedPrompt)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = promptWithoutPaths.isEmpty
            ? "Analyze the attached files."
            : promptWithoutPaths
        let sessionID: UUID
        if let editAndResendSource {
            guard let forkedSessionID = forkSession(
                sourceSessionID: editAndResendSource.sessionID,
                sourceMessageID: editAndResendSource.messageID,
                reason: .editAndResend
            ) else { return }
            sessionID = forkedSessionID
            self.editAndResendSource = nil
        } else {
            guard let selectedSessionID else { return }
            sessionID = selectedSessionID
        }
        let generationID = UUID()
        composerText = ""
        draftAttachments = []
        attachmentErrorMessage = nil
        pendingLocalFileAuthorization = nil
        activeGenerationID = generationID
        activeGenerationConfiguration = configuration
        activeGenerationSessionID = sessionID
        activeAssistantMessageID = nil
        activeToolMessageID = nil
        isStreaming = true
        statusMessage = configuration.thinkingEnabled
            ? String(localized: "Thinking…")
            : String(localized: "Generating…")
        responseTask = Task { [weak self] in
            await self?.performSend(
                prompt,
                attachments: attachments,
                sessionID: sessionID,
                generationID: generationID,
                configuration: configuration
            )
        }
    }

    public func stop() {
        guard isStreaming, let generationID = activeGenerationID else { return }
        statusMessage = String(localized: "Stopping…")
        let task = responseTask
        task?.cancel()
        Task { [weak self] in
            guard let self else { return }
            await self.ollamaClient.cancel()
            await self.webTools.cancel()
            _ = await task?.result
            await self.finishStoppedGeneration(generationID)
        }
    }

    public func refreshModels() async {
        guard !isStreaming else { return }
        ollamaReadiness = .checking
        statusMessage = String(localized: "Connecting to Ollama…")
        do {
            baseURL = OllamaClient.localBaseURL.absoluteString
            try await ollamaClient.setBaseURL(baseURL)
            let version = try await ollamaClient.version()
            guard Self.isVersion(version, atLeast: OllamaClient.minimumVersion) else {
                models = []
                ollamaReadiness = .updateRequired(installedVersion: version)
                statusMessage = String(localized: "Ollama update required")
                return
            }
            let available = try await ollamaClient.models()
            models = available
            if !available.contains(where: { $0.name == selectedModel }) {
                selectedModel = OllamaClient.preferredModel(from: available)?.name
                    ?? available.first?.name
                    ?? ""
            }
            if !selectedModel.isEmpty {
                ollamaReadiness = .ready(version: version)
                statusMessage = String(localized: "Ollama connected")
            } else {
                ollamaReadiness = .modelMissing(
                    availableDiskBytes: availableDiskBytes()
                )
                statusMessage = String(localized: "No local models installed")
            }
        } catch {
            models = []
            if ollamaApplicationURL() == nil {
                ollamaReadiness = .notInstalled
                statusMessage = String(localized: "Ollama is not installed")
            } else {
                ollamaReadiness = .serviceUnavailable
                statusMessage = String(localized: "Start Ollama to continue")
            }
            await logger.log("ollama_error", fields: ["operation": "model_discovery", "error": error.localizedDescription])
        }
    }

    public func saveSettings() async {
        baseURL = OllamaClient.localBaseURL.absoluteString
        await refreshModels()
    }

    public func reloadMemories() async {
        memories = (try? await memoryStore.load()) ?? []
    }

    public func deleteMemory(_ id: UUID) {
        Task {
            try? await memoryStore.delete(id: id)
            await reloadMemories()
            await logger.log("memory_deleted", fields: ["memory_id": id.uuidString])
        }
    }

    public func openLogs() {
        Task {
            let url = await logger.logsDirectory()
            NSWorkspace.shared.open(url)
        }
    }

    public func importAttachments(_ urls: [URL]) async {
        guard !urls.isEmpty, !isStreaming, !isShuttingDown else { return }
        let importID = UUID()
        let queuedImports = urls.map { url in
            (pending: PendingAttachmentImport(
                id: UUID(),
                displayName: url.lastPathComponent
            ), url: url)
        }
        let previousImportTask = attachmentImportTask?.task
        if pendingAttachmentImportCount == 0 {
            attachmentImportIssues = []
            attachmentErrorMessage = nil
        }
        pendingAttachmentImportCount += 1
        pendingAttachmentImports.append(contentsOf: queuedImports.map(\.pending))
        isImportingAttachments = true

        let task = Task { @MainActor [weak self] in
            if let previousImportTask {
                await previousImportTask.value
            }
            guard !Task.isCancelled, let self else { return }
            await self.performAttachmentImport(queuedImports)
        }
        attachmentImportTask = (importID, task)
        await task.value

        let queuedIDs = Set(queuedImports.map(\.pending.id))
        pendingAttachmentImports.removeAll { queuedIDs.contains($0.id) }
        pendingAttachmentImportCount = max(pendingAttachmentImportCount - 1, 0)
        isImportingAttachments = pendingAttachmentImportCount > 0
        if pendingAttachmentImportCount == 0 {
            attachmentErrorMessage = attachmentImportIssues.isEmpty
                ? nil
                : attachmentImportIssues.joined(separator: "\n")
            attachmentImportIssues = []
        }
        if attachmentImportTask?.id == importID {
            attachmentImportTask = nil
        }
    }

    private func performAttachmentImport(
        _ queuedImports: [(pending: PendingAttachmentImport, url: URL)]
    ) async {
        var issues: [String] = []
        var reachedLimit = false
        attachmentLoop: for queuedImport in queuedImports {
            if draftAttachments.count >= AttachmentStore.maximumAttachmentsPerChat {
                reachedLimit = true
                break
            }
            do {
                let attachment = try await attachmentStore.importFile(
                    at: queuedImport.url
                )
                if draftAttachments.contains(where: { $0.sha256 == attachment.sha256 }) {
                    pendingAttachmentImports.removeAll { $0.id == queuedImport.pending.id }
                    continue attachmentLoop
                }
                guard draftAttachments.count < AttachmentStore.maximumAttachmentsPerChat else {
                    scheduleDocumentProfilePreparation(for: attachment)
                    reachedLimit = true
                    pendingAttachmentImports.removeAll { $0.id == queuedImport.pending.id }
                    break attachmentLoop
                }
                draftAttachments.append(attachment)
                scheduleDocumentProfilePreparation(for: attachment)
            } catch {
                issues.append(
                    "\(queuedImport.url.lastPathComponent): \(error.localizedDescription)"
                )
            }
            pendingAttachmentImports.removeAll { $0.id == queuedImport.pending.id }
        }
        if reachedLimit {
            issues.append(
                "A chat can include up to \(AttachmentStore.maximumAttachmentsPerChat) files; extra files were not attached."
            )
        }
        for issue in issues where !attachmentImportIssues.contains(issue) {
            attachmentImportIssues.append(issue)
        }
    }

    public func handleUserSelectedFiles(_ urls: [URL]) async {
        if pendingLocalFileAuthorization != nil {
            await authorizePendingLocalFiles(urls)
        } else {
            await importAttachments(urls)
        }
    }

    public func authorizePendingLocalFiles(_ urls: [URL]) async {
        guard let request = pendingLocalFileAuthorization, !urls.isEmpty else { return }
        let existingIDs = Set(draftAttachments.map(\.id))
        await importAttachments(urls)
        let imported = draftAttachments.contains {
            !existingIDs.contains($0.id)
        }
        guard imported else {
            statusMessage = String(localized: "File access was not granted")
            return
        }
        composerText = ToolPolicy.promptByRemovingLocalFilePaths(request.originalPrompt)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        pendingLocalFileAuthorization = nil
        if canSend {
            send()
        }
    }

    public func cancelLocalFileAuthorization() {
        guard pendingLocalFileAuthorization != nil else { return }
        pendingLocalFileAuthorization = nil
        attachmentErrorMessage = String(localized: "File access was not granted.")
        statusMessage = String(localized: "File access was not granted")
    }

    public func removeDraftAttachment(_ id: UUID) {
        draftAttachments.removeAll { $0.id == id }
    }

    public func reloadLibrary(matching query: String = "") async {
        isLoadingLibrary = true
        libraryErrorMessage = nil
        defer { isLoadingLibrary = false }
        do {
            let documents = try await attachmentStore.libraryDocuments(
                matching: query
            )
            try Task.checkCancellation()
            var profiles: [UUID: DocumentProfile] = [:]
            for document in documents {
                if let profile = try await documentAnalyzer.latestCachedProfile(
                    for: document.reference
                ) {
                    profiles[document.id] = profile
                }
            }
            try Task.checkCancellation()
            libraryDocuments = documents
            libraryProfiles = profiles
        } catch is CancellationError {
        } catch {
            libraryErrorMessage = error.localizedDescription
        }
    }

    public func addLibraryDocumentToDraft(_ document: DocumentLibraryRecord) async {
        guard !isStreaming else { return }
        guard document.reference.state == .ready else {
            libraryErrorMessage = document.reference.issue?.message
                ?? "This document cannot be added to a chat."
            return
        }
        guard !draftAttachments.contains(where: {
            $0.sha256 == document.reference.sha256
        }) else {
            statusMessage = String(localized: "Document already attached")
            return
        }
        guard draftAttachments.count < AttachmentStore.maximumAttachmentsPerChat else {
            libraryErrorMessage = String(localized: "A chat can include up to \(AttachmentStore.maximumAttachmentsPerChat) documents.")
            return
        }
        do {
            let reference = try await attachmentStore.libraryReference(
                id: document.id
            )
            guard !isStreaming else { return }
            guard !draftAttachments.contains(where: {
                $0.sha256 == reference.sha256
            }) else {
                statusMessage = String(localized: "Document already attached")
                return
            }
            guard draftAttachments.count < AttachmentStore.maximumAttachmentsPerChat else {
                libraryErrorMessage = String(localized: "A chat can include up to \(AttachmentStore.maximumAttachmentsPerChat) documents.")
                return
            }
            draftAttachments.append(reference)
            statusMessage = String(localized: "Added from Library")
        } catch {
            libraryErrorMessage = error.localizedDescription
        }
    }

    public func deleteDocumentFromLibrary(_ document: DocumentLibraryRecord) async {
        guard !isStreaming else { return }
        libraryErrorMessage = nil
        await documentAnalyzer.invalidate(
            documentSHA256: document.reference.sha256
        )
        cancelDocumentProfilePreparation(
            documentSHA256: document.reference.sha256
        )
        do {
            try await attachmentStore.deleteFromLibrary(id: document.id)
            libraryDocuments.removeAll { $0.id == document.id }
            libraryProfiles[document.id] = nil
            draftAttachments.removeAll { $0.id == document.id }
            let deletedReference = Self.deletedReference(
                from: document.reference
            )
            var changedSessionIDs: [UUID] = []
            for sessionIndex in sessions.indices {
                var changed = false
                for messageIndex in sessions[sessionIndex].messages.indices {
                    guard var attachments = sessions[sessionIndex]
                        .messages[messageIndex].attachments
                    else { continue }
                    for attachmentIndex in attachments.indices
                    where attachments[attachmentIndex].id == document.id {
                        attachments[attachmentIndex] = deletedReference
                        changed = true
                    }
                    sessions[sessionIndex].messages[messageIndex].attachments = attachments
                }
                if changed { changedSessionIDs.append(sessions[sessionIndex].id) }
            }
            var historyStatePersisted = true
            for sessionID in changedSessionIDs {
                if !(await persistSessionDurably(sessionID)) {
                    historyStatePersisted = false
                }
            }
            if !changedSessionIDs.isEmpty { transcriptRevision += 1 }
            if historyStatePersisted {
                statusMessage = String(localized: "Deleted from Library")
            } else {
                statusMessage = String(localized: "Deleted from Library; chat history update failed")
                libraryErrorMessage = String(localized: "The document data was deleted, but one or more historical chat references could not be saved.")
            }
            await logger.log(
                "document_deleted",
                fields: [
                    "document_id": document.id.uuidString,
                    "history_state_saved": historyStatePersisted ? "true" : "false"
                ]
            )
        } catch {
            libraryErrorMessage = error.localizedDescription
        }
    }

    public func analyzeLibraryDocument(_ document: DocumentLibraryRecord) async {
        guard !isStreaming, activeModelDigest != nil else {
            libraryErrorMessage = String(localized: "Start Ollama and select a local model to create a profile.")
            return
        }
        libraryErrorMessage = nil
        scheduleDocumentProfilePreparation(for: document.reference)
        statusMessage = String(localized: "Local model profile queued")
    }

    public func openOllamaDownloadPage() {
        NSWorkspace.shared.open(OllamaClient.downloadPage)
    }

    public func openRecommendedModelPage() {
        NSWorkspace.shared.open(OllamaClient.modelPage)
    }

    public func openInstalledOllama() {
        guard let url = ollamaApplicationURL() else {
            openOllamaDownloadPage()
            return
        }
        NSWorkspace.shared.open(url)
    }

    public func copyModelPullCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(OllamaClient.pullCommand, forType: .string)
        statusMessage = String(localized: "Pull command copied")
    }

    public func retryAssistant(_ messageID: UUID) {
        forkAndResend(messageID: messageID, reason: .retry)
    }

    public func regenerateAssistant(_ messageID: UUID) {
        forkAndResend(messageID: messageID, reason: .regenerate)
    }

    public func beginEditAndResend(_ messageID: UUID) {
        guard !isStreaming,
              let session = currentSession,
              let message = session.messages.first(where: {
                  $0.id == messageID && $0.role == .user
              })
        else { return }
        let attachments = Self.normalizedDraftAttachments(
            message.attachments ?? []
        )
        editAndResendSource = EditAndResendSource(
            sessionID: session.id,
            messageID: message.id,
            parentTitle: session.title,
            originalContent: message.content,
            previousDraft: composerText,
            attachments: attachments,
            previousAttachments: draftAttachments
        )
        composerText = message.content
        draftAttachments = attachments
        statusMessage = String(localized: "Editing creates a new chat")
    }

    public func cancelEditAndResend() {
        guard let editAndResendSource else { return }
        composerText = editAndResendSource.previousDraft
        draftAttachments = editAndResendSource.previousAttachments
        self.editAndResendSource = nil
        statusMessage = ollamaReadiness.isReady
            ? String(localized: "Ready")
            : statusMessage
    }

    private static func normalizedDraftAttachments(
        _ attachments: [AttachmentReference]
    ) -> [AttachmentReference] {
        var seenSHA256: Set<String> = []
        var normalized: [AttachmentReference] = []
        for attachment in attachments
        where normalized.count < AttachmentStore.maximumAttachmentsPerChat {
            guard seenSHA256.insert(attachment.sha256).inserted else { continue }
            normalized.append(attachment)
        }
        return normalized
    }

    static func isVersion(_ version: String, atLeast minimum: String) -> Bool {
        let lhs = version.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = minimum.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return true
    }

    private func forkAndResend(
        messageID: UUID,
        reason: SessionForkReason
    ) {
        guard !isStreaming,
              ollamaReadiness.isReady,
              let session = currentSession,
              let assistantIndex = session.messages.firstIndex(where: {
                  $0.id == messageID && $0.role == .assistant
              }),
              let userIndex = session.messages[..<assistantIndex]
                .lastIndex(where: { $0.role == .user })
        else { return }
        let prompt = session.messages[userIndex].content
        let attachments = Self.normalizedDraftAttachments(
            session.messages[userIndex].attachments ?? []
        )
        if let unavailable = attachments.first(where: { $0.state != .ready }) {
            statusMessage = unavailable.issue?.message
                ?? "A referenced document is no longer available."
            return
        }
        let savedDraft = composerText
        let savedAttachments = draftAttachments
        guard forkSession(
            sourceSessionID: session.id,
            sourceMessageID: messageID,
            reason: reason
        ) != nil else { return }
        composerText = prompt
        draftAttachments = attachments
        send()
        composerText = savedDraft
        draftAttachments = savedAttachments
    }

    @discardableResult
    private func forkSession(
        sourceSessionID: UUID,
        sourceMessageID: UUID,
        reason: SessionForkReason
    ) -> UUID? {
        guard let source = sessions.first(where: { $0.id == sourceSessionID }),
              let sourceIndex = source.messages.firstIndex(where: {
                  $0.id == sourceMessageID
              })
        else { return nil }

        let userIndex: Int
        if source.messages[sourceIndex].role == .user {
            userIndex = sourceIndex
        } else if let precedingUser = source.messages[..<sourceIndex]
            .lastIndex(where: { $0.role == .user }) {
            userIndex = precedingUser
        } else {
            return nil
        }
        let label: String
        switch reason {
        case .retry: label = "Retry"
        case .regenerate: label = "Regenerated"
        case .editAndResend: label = "Edited"
        }
        let branch = ChatSession(
            title: String("\(source.title) · \(label)".prefix(64)),
            messages: Array(source.messages[..<userIndex]),
            fork: SessionFork(
                parentSessionID: source.id,
                parentTitle: source.title,
                sourceMessageID: sourceMessageID,
                reason: reason
            )
        )
        sessions.insert(branch, at: 0)
        selectedSessionID = branch.id
        transcriptRevision += 1
        persistSession(branch.id)
        return branch.id
    }

    private var activeModelDigest: String? {
        guard let digest = models.first(where: { $0.name == selectedModel })?.digest?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !digest.isEmpty
        else { return nil }
        return digest
    }

    private func scheduleDocumentProfilePreparation(
        for attachment: AttachmentReference
    ) {
        guard attachment.state == .ready,
              ollamaReadiness.isReady,
              let modelDigest = activeModelDigest
        else { return }
        let warmup = DocumentProfileWarmup(
            attachment: attachment,
            modelName: selectedModel,
            modelDigest: modelDigest
        )
        guard documentProfileWarmupKeys.insert(warmup.key).inserted else { return }
        documentProfileWarmupQueue.append(warmup)
        startNextDocumentProfileWarmupIfPossible()
    }

    private func startNextDocumentProfileWarmupIfPossible() {
          guard !isStreaming,
              !isShuttingDown,
              documentProfileTask == nil,
              !documentProfileWarmupQueue.isEmpty
        else { return }
        let warmup = documentProfileWarmupQueue.removeFirst()
        activeDocumentProfileWarmup = warmup
        let analyzer = documentAnalyzer
        let eventLogger = logger
        documentProfileTask = Task { @MainActor [weak self] in
            let profile: DocumentProfile?
            do {
                profile = try await analyzer.profile(
                    for: warmup.attachment,
                    modelName: warmup.modelName,
                    modelDigest: warmup.modelDigest
                )
                await eventLogger.log(
                    "document_profile_ready",
                    model: warmup.modelName,
                    fields: ["document_id": warmup.attachment.id.uuidString]
                )
            } catch is CancellationError {
                profile = nil
            } catch {
                profile = nil
                await eventLogger.log(
                    "document_profile_error",
                    model: warmup.modelName,
                    fields: [
                        "document_id": warmup.attachment.id.uuidString,
                        "error": error.localizedDescription
                    ]
                )
            }
            guard let self else { return }
            if let profile {
                self.libraryProfiles[warmup.attachment.id] = profile
            }
            self.documentProfileWarmupKeys.remove(warmup.key)
            self.activeDocumentProfileWarmup = nil
            self.documentProfileTask = nil
            self.startNextDocumentProfileWarmupIfPossible()
        }
    }

    private func cancelDocumentProfilePreparation(documentSHA256: String) {
        let removedKeys = documentProfileWarmupQueue
            .filter { $0.attachment.sha256 == documentSHA256 }
            .map(\.key)
        documentProfileWarmupQueue.removeAll {
            $0.attachment.sha256 == documentSHA256
        }
        documentProfileWarmupKeys.subtract(removedKeys)
        if activeDocumentProfileWarmup?.attachment.sha256 == documentSHA256 {
            documentProfileTask?.cancel()
        }
    }

    private func documentProfiles(
        for attachments: [AttachmentReference],
        configuration: GenerationConfiguration
    ) async throws -> [UUID: DocumentProfile] {
        guard let modelDigest = configuration.modelDigest else { return [:] }
        var profiles: [UUID: DocumentProfile] = [:]
        if !attachments.isEmpty {
            statusMessage = String(localized: "Preparing local documents…")
        }
        for attachment in attachments where attachment.state == .ready {
            do {
                let profile = try await profileForSend(
                    attachment,
                    modelName: configuration.modelName,
                    modelDigest: modelDigest
                )
                profiles[attachment.id] = profile
                libraryProfiles[attachment.id] = profile
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                await logger.log(
                    "document_profile_error",
                    model: configuration.modelName,
                    fields: [
                        "document_id": attachment.id.uuidString,
                        "error": error.localizedDescription
                    ]
                )
            }
        }
        if !attachments.isEmpty {
            statusMessage = configuration.thinkingEnabled
                ? String(localized: "Thinking…")
                : String(localized: "Generating…")
        }
        return profiles
    }

    private func profileForSend(
        _ attachment: AttachmentReference,
        modelName: String,
        modelDigest: String
    ) async throws -> DocumentProfile {
        let requested = DocumentProfileWarmup(
            attachment: attachment,
            modelName: modelName,
            modelDigest: modelDigest
        )
        if let active = activeDocumentProfileWarmup,
           active.key != requested.key,
           let activeTask = documentProfileTask {
            activeTask.cancel()
            await activeTask.value
            try Task.checkCancellation()
            if documentProfileWarmupKeys.insert(active.key).inserted {
                documentProfileWarmupQueue.insert(active, at: 0)
            }
        }
        if let queuedIndex = documentProfileWarmupQueue.firstIndex(where: {
            $0.key == requested.key
        }) {
            documentProfileWarmupQueue.remove(at: queuedIndex)
            documentProfileWarmupKeys.remove(requested.key)
        }
        return try await documentAnalyzer.profile(
            for: attachment,
            modelName: modelName,
            modelDigest: modelDigest
        )
    }

    private func performSend(
        _ prompt: String,
        attachments: [AttachmentReference],
        sessionID: UUID,
        generationID: UUID,
        configuration: GenerationConfiguration
    ) async {
        guard activeGenerationID == generationID,
              let originalIndex = sessions.firstIndex(where: { $0.id == sessionID })
        else { return }
        let previousMessages = sessions[originalIndex].messages
        let wasFirstPrompt = !previousMessages.contains { $0.role == .user }
        if wasFirstPrompt { sessions[originalIndex].title = ChatSession.title(from: prompt) }
        let userMessage = ChatMessage(
            role: .user,
            content: prompt,
            attachments: attachments.isEmpty ? nil : attachments
        )
        sessions[originalIndex].messages.append(userMessage)
        requestedScrollMessageID = userMessage.id
        requestedScrollRequestID = UUID()
        sessions[originalIndex].updatedAt = Date()
        sortSessionsKeepingSelection()

        performance = PerformanceStats()
        performance.model = configuration.modelName
        performance.thinkingEnabled = configuration.thinkingEnabled
        liveGenerationMeter = LiveGenerationMeter()
        lastCheckpointCharacters = 0
        transcriptRevision += 1
        persistSession(sessionID)

        let selectedMemories = (try? await memoryStore.relevant(to: prompt)) ?? []
        let attachmentContext: AttachmentContext?
        do {
            let profiles = try await documentProfiles(
                for: attachments,
                configuration: configuration
            )
            attachmentContext = attachments.isEmpty
                ? nil
                : try await attachmentStore.context(
                    for: attachments,
                    query: prompt,
                    profiles: profiles
                )
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            activeAssistantMessageID = appendMessage(
                ChatMessage(
                    role: .assistant,
                    content: "The attached files could not be prepared.",
                    responseState: .failed,
                    responseIssue: AssistantResponseIssue(
                        code: .unknown,
                        message: error.localizedDescription
                    )
                ),
                to: sessionID
            )
            statusMessage = String(localized: "Attachment failed")
            _ = await persistSessionDurably(sessionID)
            finishGeneration(generationID)
            return
        }
        let jsonFormat = ToolPolicy.shouldRequestJSONFormat(for: prompt)
        let allowedToolNames = jsonFormat ? [] : ToolPolicy.modelActionToolNames
        let toolSchemaTokens = allowedToolNames.count * 500
        let contextPlan: ContextPlan
        do {
            contextPlan = try ContextPlanner.plan(
                history: previousMessages,
                prompt: prompt,
                memories: selectedMemories,
                thinking: configuration.thinkingEnabled,
                toolSchemaTokens: toolSchemaTokens,
                attachmentContext: attachmentContext
            )
        } catch {
            let issue = responseIssue(for: error)
            activeAssistantMessageID = appendMessage(
                ChatMessage(
                    role: .assistant,
                    content: "This request is too large for the current context window.",
                    responseState: .failed,
                    responseIssue: issue
                ),
                to: sessionID
            )
            statusMessage = String(localized: "Request too large")
            markSessionUpdated(sessionID)
            _ = await persistSessionDurably(sessionID)
            finishGeneration(generationID)
            await logger.log(
                "request_error",
                sessionID: sessionID,
                model: configuration.modelName,
                fields: ["error": error.localizedDescription]
            )
            return
        }
        performance.contextEstimate = contextPlan.receipt.estimatedPromptTokens
        performance.contextWindow = contextPlan.receipt.contextWindow
        performance.compactedTurns = contextPlan.receipt.compactedTurns
        performance.omittedTurns = contextPlan.receipt.omittedTurns
        var conversation = contextPlan.messages
        let requestStartedAt = Date()
        await logger.log(
            "request_started",
            sessionID: sessionID,
            model: configuration.modelName,
            fields: [
                "mode": configuration.thinkingEnabled ? "thinking" : "fast"
            ]
        )

        let utilityToolsEnabled = allowedToolNames.contains("code_interpreter")
        let localContextToolsEnabled = allowedToolNames.contains("local_context")
        let modelInformationToolsEnabled = !allowedToolNames.isDisjoint(with: [
            "local_search", "web_search", "fetch_url",
            "browser_snapshot", "browser_extract"
        ])

        var finalAnswer = ""
        var successfulToolNames: Set<String> = Set(
            previousMessages.compactMap { message in
                guard message.role == .tool,
                      message.tool?.status == .success else { return nil }
                return message.tool?.name
            }
        )
        var actionCorrectionCount = 0
        do {
            for round in 0..<6 {
                try Task.checkCancellation()
                try ContextPlanner.validateDynamicConversation(
                    conversation,
                    outputReserve: contextPlan.receipt.outputReserve,
                    toolSchemaTokens: toolSchemaTokens,
                    contextWindow: contextPlan.receipt.contextWindow
                )
                liveGenerationMeter.beginRound()
                let assistantID = appendMessage(
                    ChatMessage(
                        role: .assistant,
                        content: "",
                        responseState: .streaming,
                        contextReceipt: contextPlan.receipt
                    ),
                    to: sessionID
                )
                activeAssistantMessageID = assistantID
                persistSession(sessionID)
                let result = try await ollamaClient.streamChat(
                    model: configuration.modelName,
                    messages: conversation,
                    thinking: configuration.thinkingEnabled,
                    toolsEnabled: modelInformationToolsEnabled,
                    utilityToolsEnabled: utilityToolsEnabled,
                    localContextToolsEnabled: localContextToolsEnabled,
                    allowedToolNames: allowedToolNames,
                    jsonFormat: jsonFormat,
                    contextWindow: contextPlan.receipt.contextWindow,
                    maximumOutputTokens: contextPlan.receipt.outputReserve
                ) { [weak self] event in
                    await self?.consume(
                        event,
                        messageID: assistantID,
                        sessionID: sessionID,
                        generationID: generationID,
                        requestStartedAt: requestStartedAt
                    )
                }
                performance.promptTokens = result.promptTokens
                let finalMetrics = liveGenerationMeter.finishRound(
                    exactTokens: result.outputTokens,
                    evaluationDurationNanoseconds: result.evaluationDurationNanoseconds
                )
                performance.outputTokens = finalMetrics.totalTokens
                performance.contextEstimate = result.promptTokens
                performance.tokensPerSecond = finalMetrics.tokensPerSecond
                let validatedCalls: [ToolInvocation]
                do {
                    guard result.toolCalls.count <= 1 else {
                        throw ToolPolicy.InvocationValidationError.invalidArguments(
                            "multiple simultaneous actions"
                        )
                    }
                    validatedCalls = try result.toolCalls.map {
                        try ToolPolicy.validateModelInvocation(
                            $0,
                            for: prompt,
                            hasAttachments: !attachments.isEmpty
                        )
                    }
                } catch {
                    if actionCorrectionCount == 0,
                       !result.toolCalls.isEmpty {
                        actionCorrectionCount += 1
                        removeMessage(id: assistantID, from: sessionID)
                        let rejectedCalls = result.toolCalls.map {
                            OllamaToolCall(
                                id: $0.id,
                                name: $0.name,
                                arguments: $0.arguments
                            )
                        }
                        conversation.append(
                            OllamaMessage(
                                role: .assistant,
                                content: "",
                                toolCalls: rejectedCalls
                            )
                        )
                        let feedback = """
                        Action rejected by the application: \(error.localizedDescription) \
                        The action was not executed. Re-read the user's request and either answer \
                        directly or select one different valid action. Do not repeat the rejected action.
                        """
                        for _ in rejectedCalls {
                            conversation.append(
                                OllamaMessage(role: .tool, content: feedback)
                            )
                        }
                        activeAssistantMessageID = nil
                        persistSession(sessionID)
                        await logger.log(
                            "action_rejected",
                            sessionID: sessionID,
                            model: configuration.modelName,
                            fields: [
                                "action": result.toolCalls.first?.name ?? "multiple",
                                "round": "\(round + 1)",
                                "recovery": "model_retry"
                            ]
                        )
                        continue
                    }
                    mutateMessage(id: assistantID, in: sessionID) { message in
                        message.content = "I couldn't safely execute the action selected by the local model."
                        message.responseState = .failed
                        message.responseIssue = AssistantResponseIssue(
                            code: .unknown,
                            message: error.localizedDescription
                        )
                        message.toolCalls = nil
                    }
                    statusMessage = String(localized: "Action blocked")
                    await logger.log(
                        "tool_rejected",
                        sessionID: sessionID,
                        model: configuration.modelName,
                        fields: ["error": error.localizedDescription]
                    )
                    markSessionUpdated(sessionID)
                    _ = await persistSessionDurably(sessionID)
                    finishGeneration(generationID)
                    return
                }
                await logger.log(
                    "action_selected",
                    sessionID: sessionID,
                    model: configuration.modelName,
                    fields: [
                        "action": validatedCalls.first?.name ?? "direct",
                        "round": "\(round + 1)"
                    ]
                )
                streamedRawContentByMessageID[assistantID] = nil
                mutateMessage(id: assistantID, in: sessionID) { message in
                    message.content = validatedCalls.isEmpty ? result.content : ""
                    if message.thinking?.isEmpty != false, !result.thinking.isEmpty {
                        message.thinking = result.thinking
                    }
                    message.responseState = .complete
                    message.toolCalls = validatedCalls.isEmpty
                        ? nil
                        : validatedCalls
                    message.contextReceipt?.actualPromptTokens = result.promptTokens
                }

                let assistantCalls = validatedCalls.map {
                    OllamaToolCall(
                        id: $0.id,
                        name: $0.name,
                        arguments: $0.arguments
                    )
                }
                conversation.append(
                    OllamaMessage(
                        role: .assistant,
                        content: result.content,
                        toolCalls: assistantCalls.isEmpty ? nil : assistantCalls
                    )
                )

                if validatedCalls.isEmpty {
                    finalAnswer = result.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if finalAnswer.isEmpty {
                        finalAnswer = "Ollama returned no visible answer."
                        mutateMessage(id: assistantID, in: sessionID) { $0.content = finalAnswer }
                    }
                    if let evidenceError = ToolPolicy.unsupportedToolClaim(
                        in: finalAnswer,
                        successfulTools: successfulToolNames
                    ) {
                        finalAnswer = ""
                        mutateMessage(id: assistantID, in: sessionID) { message in
                            message.content = "I don't have a verified tool result for that information, so I won't present it as current or sourced."
                            message.responseState = .failed
                            message.responseIssue = AssistantResponseIssue(
                                code: .unknown,
                                message: evidenceError
                            )
                        }
                        statusMessage = String(localized: "Evidence required")
                        await logger.log(
                            "answer_rejected",
                            sessionID: sessionID,
                            model: configuration.modelName,
                            fields: ["reason": "missing_tool_evidence"]
                        )
                        markSessionUpdated(sessionID)
                        _ = await persistSessionDurably(sessionID)
                        finishGeneration(generationID)
                        return
                    }
                    break
                }
                for invocation in validatedCalls {
                    try Task.checkCancellation()
                    guard allowedToolNames.contains(invocation.name) else {
                        let failure = "Tool unavailable for this request."
                        _ = appendMessage(
                            ChatMessage(
                                role: .tool,
                                content: failure,
                                tool: ToolActivity(
                                    name: invocation.name,
                                    inputSummary: inputSummary(for: invocation),
                                    reason: "This tool was not allowed for the current request.",
                                    status: .failure,
                                    detail: failure,
                                    invocation: invocation
                                )
                            ),
                            to: sessionID
                        )
                        conversation.append(
                            OllamaMessage(role: .tool, content: failure)
                        )
                        await logger.log(
                            "tool_rejected",
                            sessionID: sessionID,
                            model: configuration.modelName,
                            fields: ["tool": invocation.name]
                        )
                        continue
                    }
                    let activity = ToolActivity(
                        name: invocation.name,
                        inputSummary: inputSummary(for: invocation),
                        reason: toolReason(for: invocation),
                        invocation: invocation
                    )
                    let toolMessageID = appendMessage(
                        ChatMessage(role: .tool, content: "", tool: activity),
                        to: sessionID
                    )
                    activeToolMessageID = toolMessageID
                    let toolStartedAt = Date()
                    await logger.log(
                        "tool_started",
                        sessionID: sessionID,
                        model: configuration.modelName,
                        fields: ["tool": invocation.name, "round": "\(round + 1)"]
                    )
                    do {
                        let toolResult = try await webTools.execute(invocation)
                        try Task.checkCancellation()
                        mutateMessage(id: toolMessageID, in: sessionID) { message in
                            message.content = toolResult.content
                            message.tool?.status = .success
                            message.tool?.detail = toolDetail(
                                for: invocation,
                                result: toolResult
                            )
                            message.tool?.sources = toolResult.sources
                        }
                        conversation.append(OllamaMessage(role: .tool, content: toolResult.content))
                        successfulToolNames.insert(invocation.name)
                        activeToolMessageID = nil
                        await logger.log(
                            "tool_finished",
                            sessionID: sessionID,
                            model: configuration.modelName,
                            fields: [
                                "tool": invocation.name,
                                "status": "success",
                                "duration_ms": "\(Int(Date().timeIntervalSince(toolStartedAt) * 1_000))"
                            ]
                        )
                        if let groundedAnswer = toolResult.groundedAnswer {
                            finalAnswer = groundedAnswer
                            activeAssistantMessageID = appendMessage(
                                ChatMessage(
                                    role: .assistant,
                                    content: groundedAnswer,
                                    responseState: .complete,
                                    contextReceipt: contextPlan.receipt
                                ),
                                to: sessionID
                            )
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        let failure = "Tool failed: \(error.localizedDescription)"
                        mutateMessage(id: toolMessageID, in: sessionID) { message in
                            message.content = failure
                            message.tool?.status = .failure
                            message.tool?.detail = error.localizedDescription
                        }
                        conversation.append(OllamaMessage(role: .tool, content: failure))
                        activeToolMessageID = nil
                        await logger.log(
                            "tool_finished",
                            sessionID: sessionID,
                            model: configuration.modelName,
                            fields: [
                                "tool": invocation.name,
                                "status": "failure",
                                "duration_ms": "\(Int(Date().timeIntervalSince(toolStartedAt) * 1_000))",
                                "error": error.localizedDescription
                            ]
                        )
                        activeAssistantMessageID = appendMessage(
                            ChatMessage(
                                role: .assistant,
                                content: preflightFailureMessage(
                                    for: invocation,
                                    error: error
                                ),
                                responseState: .failed,
                                responseIssue: AssistantResponseIssue(
                                    code: .unknown,
                                    message: error.localizedDescription
                                )
                            ),
                            to: sessionID
                        )
                        statusMessage = String(localized: "Information unavailable")
                        markSessionUpdated(sessionID)
                        _ = await persistSessionDurably(sessionID)
                        finishGeneration(generationID)
                        return
                    }
                }
                if !finalAnswer.isEmpty { break }
            }
            if finalAnswer.isEmpty {
                let message = "The information-retrieval loop reached its six-round safety limit without a final answer."
                _ = appendMessage(
                    ChatMessage(
                        role: .assistant,
                        content: message,
                        responseState: .complete
                    ),
                    to: sessionID
                )
                finalAnswer = message
            }
            statusMessage = String(localized: "Ready")
            await logger.log(
                "request_finished",
                sessionID: sessionID,
                model: configuration.modelName,
                fields: [
                    "duration_ms": "\(Int(Date().timeIntervalSince(requestStartedAt) * 1_000))",
                    "prompt_tokens": "\(performance.promptTokens)",
                    "output_tokens": "\(performance.outputTokens)",
                    "tool_rounds_max": "6"
                ]
            )
        } catch is CancellationError {
            markActiveAssistant(.stopped, generationID: generationID)
        } catch {
            if Task.isCancelled {
                markActiveAssistant(.stopped, generationID: generationID)
            } else {
                statusMessage = String(localized: "Request failed")
                let issue = responseIssue(for: error)
                if let assistantID = activeAssistantMessageID {
                    mutateMessage(id: assistantID, in: sessionID) { message in
                        if message.content.isEmpty {
                            message.content = "Request failed."
                        }
                        message.responseState = .failed
                        message.responseIssue = issue
                    }
                } else {
                    activeAssistantMessageID = appendMessage(
                        ChatMessage(
                            role: .assistant,
                            content: "Request failed.",
                            responseState: .failed,
                            responseIssue: issue
                        ),
                        to: sessionID
                    )
                }
                await logger.log(
                    "request_error",
                    sessionID: sessionID,
                    model: configuration.modelName,
                    fields: ["error": error.localizedDescription]
                )
            }
        }

        markSessionUpdated(sessionID)
        _ = await persistSessionDurably(sessionID)
        if Task.isCancelled { return }
        finishGeneration(generationID)
        if !finalAnswer.isEmpty, !Task.isCancelled {
            enqueueMemoryProcessing(sessionID: sessionID)
        }
    }

    private func responseIssue(for error: Error) -> AssistantResponseIssue {
        if error is ContextPlanningError {
            return AssistantResponseIssue(
                code: .contextOverflow,
                message: error.localizedDescription
            )
        }
        if let urlError = error as? URLError {
            return AssistantResponseIssue(
                code: urlError.code == .timedOut ? .timeout : .transport,
                message: urlError.localizedDescription
            )
        }
        switch error {
        case OllamaError.incompleteStream, OllamaError.invalidResponse,
             OllamaError.stream:
            return AssistantResponseIssue(
                code: .invalidStream,
                message: error.localizedDescription
            )
        default:
            return AssistantResponseIssue(
                code: .unknown,
                message: error.localizedDescription
            )
        }
    }

    private func consume(
        _ event: OllamaStreamEvent,
        messageID: UUID,
        sessionID: UUID,
        generationID: UUID,
        requestStartedAt: Date
    ) {
        guard isStreaming, activeGenerationID == generationID else { return }
        let streamedCharacters: Int
        switch event {
        case .content(let chunk), .thinking(let chunk):
            streamedCharacters = chunk.count
        case .replaceContent:
            streamedCharacters = 0
        }
        if streamedCharacters > 0 {
            if performance.ttftSeconds == nil {
                performance.ttftSeconds = Date().timeIntervalSince(requestStartedAt)
            }
            let live = liveGenerationMeter.ingest(
                characterCount: streamedCharacters
            )
            performance.outputTokens = live.totalTokens
            performance.tokensPerSecond = live.tokensPerSecond
        }
        mutateMessage(id: messageID, in: sessionID) { message in
            switch event {
            case .content(let chunk):
                let raw = (streamedRawContentByMessageID[messageID] ?? "") + chunk
                streamedRawContentByMessageID[messageID] = raw
                message.content = OllamaContentNormalizer.visibleContent(
                    raw,
                    thinkingEnabled: activeGenerationConfiguration?.thinkingEnabled ?? false
                )
            case .replaceContent(let content):
                streamedRawContentByMessageID[messageID] = content
                message.content = content
            case .thinking(let chunk):
                if !chunk.isEmpty {
                    message.thinking = (message.thinking ?? "") + chunk
                }
            }
        }
        if let session = sessions.first(where: { $0.id == sessionID }),
           let message = session.messages.first(where: { $0.id == messageID }) {
            let currentCharacters = message.content.count + (message.thinking?.count ?? 0)
            if currentCharacters - lastCheckpointCharacters >= 1_024 {
                lastCheckpointCharacters = currentCharacters
                persistSession(sessionID)
            }
        }
    }

    @discardableResult
    private func appendMessage(_ message: ChatMessage, to sessionID: UUID) -> UUID {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else {
            return message.id
        }
        sessions[index].messages.append(message)
        transcriptRevision += 1
        return message.id
    }

    private func mutateMessage(
        id: UUID,
        in sessionID: UUID,
        change: (inout ChatMessage) -> Void
    ) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let messageIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == id })
        else { return }
        change(&sessions[sessionIndex].messages[messageIndex])
        transcriptRevision += 1
    }

    private func removeMessage(id: UUID, from sessionID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              let messageIndex = sessions[sessionIndex].messages.firstIndex(where: {
                  $0.id == id
              }) else { return }
        sessions[sessionIndex].messages.remove(at: messageIndex)
        messageSearchTextCache[id] = nil
        streamedRawContentByMessageID[id] = nil
        transcriptRevision += 1
    }

    private func markSessionUpdated(_ sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else {
            return
        }
        sessions[index].updatedAt = Date()
        sortSessionsKeepingSelection()
    }

    private func markActiveAssistant(
        _ state: AssistantResponseState,
        generationID: UUID
    ) {
        guard activeGenerationID == generationID,
              let sessionID = activeGenerationSessionID,
              let assistantID = activeAssistantMessageID
        else { return }
        mutateMessage(id: assistantID, in: sessionID) { message in
            message.responseState = state
        }
    }

    private func finishGeneration(_ generationID: UUID) {
        guard activeGenerationID == generationID else { return }
        isStreaming = false
        responseTask = nil
        activeGenerationID = nil
        activeGenerationConfiguration = nil
        activeGenerationSessionID = nil
        activeAssistantMessageID = nil
        activeToolMessageID = nil
        streamedRawContentByMessageID.removeAll()
        startNextDocumentProfileWarmupIfPossible()
    }

    private func finishStoppedGeneration(_ generationID: UUID) async {
        guard activeGenerationID == generationID else { return }
        let sessionID = activeGenerationSessionID
        let model = activeGenerationConfiguration?.modelName ?? selectedModel
        markActiveAssistant(.stopped, generationID: generationID)
        if let sessionID, activeAssistantMessageID == nil {
            activeAssistantMessageID = appendMessage(
                ChatMessage(
                    role: .assistant,
                    content: "Stopped.",
                    responseState: .stopped
                ),
                to: sessionID
            )
        }
        if let sessionID, let toolMessageID = activeToolMessageID {
            mutateMessage(id: toolMessageID, in: sessionID) { message in
                message.content = message.content.isEmpty ? "Stopped." : message.content
                message.tool?.status = .failure
                message.tool?.detail = "Stopped by the user."
            }
        }
        statusMessage = String(localized: "Stopped")
        if let sessionID {
            markSessionUpdated(sessionID)
            _ = await persistSessionDurably(sessionID)
        }
        await logger.log(
            "request_cancelled",
            sessionID: sessionID,
            model: model
        )
        finishGeneration(generationID)
    }

    private func sortSessionsKeepingSelection() {
        sessions.sort { $0.updatedAt > $1.updatedAt }
    }

    private func persistSession(_ sessionID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        let revision = nextPersistenceRevision()
        Task {
            do {
                try await sessionStore.save(session, revision: revision)
            } catch {
                await logger.log(
                    "session_save_error",
                    sessionID: session.id,
                    fields: ["error": error.localizedDescription]
                )
            }
        }
    }

    @discardableResult
    private func persistSessionDurably(_ sessionID: UUID) async -> Bool {
        guard let session = sessions.first(where: { $0.id == sessionID }) else {
            return false
        }
        let revision = nextPersistenceRevision()
        do {
            try await sessionStore.save(session, revision: revision)
            return true
        } catch {
            statusMessage = String(localized: "Chat save failed")
            await logger.log(
                "session_save_error",
                sessionID: session.id,
                fields: ["error": error.localizedDescription]
            )
            return false
        }
    }

    private func nextPersistenceRevision() -> UInt64 {
        persistenceRevision &+= 1
        return persistenceRevision
    }

    private func inputSummary(for invocation: ToolInvocation) -> String {
        switch invocation.name {
        case "local_search":
            return String(
                (invocation.arguments["query"]?.stringValue
                    ?? "Nearby places").prefix(180)
            )
        case "local_context":
            if let fields = invocation.arguments["fields"]?.arrayValue?
                .compactMap(\.stringValue)
                .joined(separator: ", "),
               !fields.isEmpty {
                return fields
            }
            return "Local context"
        case "web_search":
            return String((invocation.arguments["query"]?.stringValue ?? "search").prefix(160))
        case "fetch_url", "browser_snapshot", "browser_extract":
            return String((invocation.arguments["url"]?.stringValue ?? "URL").prefix(180))
        case "code_interpreter":
            return String(
                (invocation.arguments["expression"]?.stringValue
                    ?? "Local expression").prefix(180)
            )
        default:
            return "Information retrieval"
        }
    }

    private func toolDetail(
        for invocation: ToolInvocation,
        result: ToolResult
    ) -> String {
        invocation.name == "local_context" ? result.content : result.summary
    }

    private func preflightFailureMessage(
        for invocation: ToolInvocation,
        error: Error
    ) -> String {
        switch invocation.name {
        case "local_search":
            return "I couldn't retrieve nearby places from Apple Maps, so I won't invent recommendations. \(error.localizedDescription)"
        case "local_context":
            return "I couldn't read the required current information from this Mac. \(error.localizedDescription)"
        case "web_search", "fetch_url":
            return "I couldn't retrieve the external information needed to answer reliably. \(error.localizedDescription)"
        case "code_interpreter":
            return "I couldn't complete the requested local calculation. \(error.localizedDescription)"
        default:
            return "I couldn't complete the required action. \(error.localizedDescription)"
        }
    }

    private func toolReason(for invocation: ToolInvocation) -> String {
        if invocation.name == "code_interpreter" {
            return "A deterministic local calculation is more reliable than estimating the result."
        }
        if invocation.name == "local_context" || invocation.name == "local_search" {
            return "The local model selected current local information to complete the answer."
        }
        return "The local model selected external information to complete the answer."
    }

    private func enqueueMemoryProcessing(sessionID: UUID) {
        guard memoryProcessingEnabled else { return }
        if !pendingMemorySessionIDs.contains(sessionID) {
            pendingMemorySessionIDs.append(sessionID)
        }
        startMemoryWorkerIfNeeded()
    }

    private func startMemoryWorkerIfNeeded() {
        guard memoryTask == nil, !pendingMemorySessionIDs.isEmpty else { return }
        memoryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
                guard let self else { return }
                if self.isStreaming {
                    self.memoryTask = nil
                    self.startMemoryWorkerIfNeeded()
                    return
                }
                let sessionID = self.pendingMemorySessionIDs.removeFirst()
                await self.processMemory(sessionID: sessionID)
                self.memoryTask = nil
                self.startMemoryWorkerIfNeeded()
            } catch {
                return
            }
        }
    }

    private func processMemory(sessionID: UUID) async {
        guard !isStreaming else { return }
        guard let session = sessions.first(where: { $0.id == sessionID }),
              let user = session.messages.last(where: { $0.role == .user })?.content,
              let assistant = session.messages.last(where: { $0.role == .assistant })?.content,
              !selectedModel.isEmpty
        else { return }
        let exchange = "User: \(user)\nAssistant: \(assistant)"
        let messages = [
            OllamaMessage(
                role: .system,
                content: """
                Extract at most one very short durable user preference or fact useful in later chats. \
                Do not store transient requests, sensitive secrets, or assistant prose. Return only \
                the memory sentence, or exactly NONE when nothing is durable.
                """
            ),
            OllamaMessage(role: .user, content: String(exchange.prefix(5_000)))
        ]
        do {
            let result = try await memoryOllamaClient.streamChat(
                model: selectedModel,
                messages: messages,
                thinking: false,
                toolsEnabled: false,
                utilityToolsEnabled: false,
                localContextToolsEnabled: false,
                jsonFormat: false,
                onEvent: { _ in }
            )
            let summary = result.content
                .trimmingCharacters(in: CharacterSet(charactersIn: "\" \n\t"))
            guard !summary.isEmpty, summary.uppercased() != "NONE" else { return }
            let record = MemoryRecord(
                sessionID: sessionID,
                summary: String(summary.prefix(500))
            )
            try await memoryStore.save(record)
            await reloadMemories()
            await logger.log(
                "memory_saved",
                sessionID: sessionID,
                model: selectedModel,
                fields: ["memory_id": record.id.uuidString]
            )
        } catch is CancellationError {
            return
        } catch {
            if isStreaming, !pendingMemorySessionIDs.contains(sessionID) {
                pendingMemorySessionIDs.insert(sessionID, at: 0)
            }
            await logger.log(
                "memory_error",
                sessionID: sessionID,
                model: selectedModel,
                fields: ["error": error.localizedDescription]
            )
        }
    }
}
