import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct PrivateAIApplicationRootView: View {
    @State private var phase: StartupPhase = .loading
    @State private var attemptID = UUID()
    @State private var startedAttemptID: UUID?

    public init() {}

    public var body: some View {
        Group {
            switch phase {
            case .loading:
                VStack(spacing: 14) {
                    ProgressView()
                    Text("Opening local data")
                        .font(.headline)
                    Text("PrivateAI keeps chats, memories, and documents on this Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("startup.loading")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready(let viewModel):
                LocalChatRootView(viewModel: viewModel)
            case .failed(let message):
                VStack(spacing: 16) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("Local data unavailable")
                        .font(.title2.weight(.semibold))
                    Text("PrivateAI could not safely open its on-device data. Nothing was reset and no cloud fallback was used.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 460)
                    Text(message)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .frame(maxWidth: 520)
                    HStack(spacing: 10) {
                        Button {
                            phase = .loading
                            attemptID = UUID()
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("startup.retry")

                        Button {
                            if let dataDirectory {
                                NSWorkspace.shared.open(dataDirectory)
                            }
                        } label: {
                            Label("Open Data Folder", systemImage: "folder")
                        }
                        .disabled(dataDirectory == nil)
                    }
                }
                .padding(36)
                .accessibilityIdentifier("startup.failure")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: attemptID) {
            guard startedAttemptID != attemptID else { return }
            startedAttemptID = attemptID
            await start(attemptID)
        }
        .onAppear {
            #if DEBUG
            guard ProcessInfo.processInfo.arguments.contains(
                "--privateai-ui-test-store-assets"
            ) else { return }
            Task { @MainActor in
                await Task.yield()
                guard let window = NSApplication.shared.windows.first else { return }
                window.setFrame(
                    NSRect(x: 0, y: 0, width: 1440, height: 900),
                    display: true
                )
                window.center()
            }
            #endif
        }
    }

    private var dataDirectory: URL? {
        try? LocalChatPaths.applicationSupportRoot()
    }

    @MainActor
    private func start(_ attempt: UUID) async {
        do {
            let viewModel = try await ChatViewModel.configuredForLaunch()
            try await viewModel.bootstrap()
            try Task.checkCancellation()
            guard attempt == attemptID else { return }
            phase = .ready(viewModel)
        } catch is CancellationError {
        } catch {
            guard attempt == attemptID else { return }
            phase = .failed(error.localizedDescription)
        }
    }
}

private enum StartupPhase {
    case loading
    case ready(ChatViewModel)
    case failed(String)
}

public struct LocalChatRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @StateObject private var viewModel: ChatViewModel
    @State private var showSettings = false
    @State private var showMemories = false
    @State private var showLibrary = false
    @State private var showModelStatus = false
    @State private var hoveredSessionID: UUID?
    @State private var renameSessionID: UUID?
    @State private var renameText = ""

    public init(viewModel: ChatViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    public var body: some View {
        NavigationSplitView {
            sessionSidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 300)
        } detail: {
            VStack(spacing: 0) {
                if !viewModel.ollamaReadiness.isReady {
                    OllamaSetupBand(viewModel: viewModel)
                    Divider()
                }
                if let fork = viewModel.currentSession?.fork {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.triangle.branch")
                        Text("Branched from \(fork.parentTitle)")
                            .lineLimit(1)
                        Spacer()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.bar)
                    .accessibilityIdentifier("chat.branch")
                    Divider()
                }
                PerformanceBanner(
                    stats: viewModel.performance,
                    selectedModel: viewModel.selectedModel,
                    isStreaming: viewModel.isStreaming
                )
                Divider()
                if let activity = viewModel.currentAgentActivity {
                    AgentActivityBand(activity: activity)
                    Divider()
                }
                ConversationView(viewModel: viewModel)
                Divider()
                ComposerArea(viewModel: viewModel)
            }
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        showModelStatus.toggle()
                    } label: {
                        Label(
                            viewModel.selectedModel.isEmpty
                                ? "Models"
                                : viewModel.selectedModel,
                            systemImage: viewModel.ollamaReadiness.isReady
                                ? "cpu.fill"
                                : "cpu"
                        )
                        .lineLimit(1)
                    }
                    .help("Model status")
                    .accessibilityLabel("Model status")
                    .accessibilityValue(modelStatusAccessibilityValue)
                    .accessibilityIdentifier("model-status.open")
                    .popover(isPresented: $showModelStatus, arrowEdge: .top) {
                        ModelStatusPopover(viewModel: viewModel)
                    }

                    Button {
                        showLibrary = true
                    } label: {
                        Label("Library", systemImage: "books.vertical")
                    }
                    .help("Document Library")
                    .accessibilityIdentifier("library.open")

                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("settings.open")

                    Button {
                        showMemories = true
                    } label: {
                        Label("Memories", systemImage: "brain")
                    }

                    Button {
                        viewModel.openLogs()
                    } label: {
                        Label("Open Logs", systemImage: "doc.text.magnifyingglass")
                    }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, !viewModel.ollamaReadiness.isReady else { return }
            Task { await viewModel.refreshModels() }
        }
        .onReceive(NotificationCenter.default.publisher(for: LocalChatNotifications.newSession)) { _ in
            viewModel.newSession()
        }
        .onDisappear {
            Task { await viewModel.shutdown() }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(viewModel: viewModel, isPresented: $showSettings)
        }
        .sheet(isPresented: $showMemories) {
            MemorySheet(viewModel: viewModel, isPresented: $showMemories)
        }
        .sheet(isPresented: $showLibrary) {
            DocumentLibrarySheet(
                viewModel: viewModel,
                isPresented: $showLibrary
            )
        }
        .alert(
            "Rename chat",
            isPresented: Binding(
                get: { renameSessionID != nil },
                set: { if !$0 { renameSessionID = nil } }
            )
        ) {
            TextField("Chat title", text: $renameText)
            Button("Cancel", role: .cancel) { renameSessionID = nil }
            Button("Rename") {
                if let renameSessionID {
                    viewModel.renameSession(renameSessionID, to: renameText)
                }
                renameSessionID = nil
            }
            .keyboardShortcut(.defaultAction)
        }
        .accessibilityIdentifier("chat.root")
    }

    private var modelStatusAccessibilityValue: String {
        switch viewModel.ollamaReadiness {
        case .checking:
            String(localized: "Checking")
        case .ready:
            viewModel.selectedModel
        default:
            String(localized: "Unavailable")
        }
    }

    private var sessionSidebar: some View {
        let searchResults = viewModel.sessionSearchResults
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Label {
                        Text("PrivateAI")
                    } icon: {
                        Image(nsImage: NSApplication.shared.applicationIconImage)
                            .resizable()
                            .renderingMode(.original)
                            .scaledToFit()
                            .frame(width: 36, height: 36)
                            .phaseAnimator(
                                accessibilityReduceMotion || scenePhase != .active
                                    ? [false]
                                    : [false, true]
                            ) { content, isLifted in
                                content
                                    .scaleEffect(isLifted ? 1.04 : 1)
                                    .offset(y: isLifted ? -1.5 : 0)
                            } animation: { isLifted in
                                isLifted
                                    ? .easeInOut(duration: 0.7).delay(2.6)
                                    : .easeInOut(duration: 0.85)
                            }
                            .frame(width: 42, height: 42)
                            .accessibilityHidden(true)
                    }
                    .font(.title3.weight(.semibold))
                    Text("Private conversations on this Mac")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    viewModel.newSession()
                } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isStreaming)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider()

            TextField(
                "Search chats",
                text: $viewModel.sessionSearchText,
                prompt: Text("Search chats")
            )
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal, 12)
            .padding(.top, 11)
            .accessibilityIdentifier("chat.search")

            Text("SESSIONS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 7)

            ScrollView {
                LazyVStack(spacing: 4) {
                    if !viewModel.sessionSearchText.isEmpty
                        && searchResults.isEmpty {
                        Text("No matching chats")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 10)
                            .accessibilityIdentifier("chat.search.empty")
                    }
                    ForEach(searchResults) { result in
                        let session = result.session
                        HStack(spacing: 4) {
                            Button {
                                viewModel.openSearchResult(result)
                            } label: {
                                HStack(spacing: 9) {
                                    Image(
                                        systemName: session.fork == nil
                                            ? "bubble.left"
                                            : "arrow.triangle.branch"
                                    )
                                        .foregroundStyle(.secondary)
                                        .frame(width: 16)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(session.title)
                                            .font(.callout)
                                            .lineLimit(1)
                                        if let snippet = result.snippet {
                                            Text(snippet)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                                .accessibilityIdentifier(
                                                    "chat.search.snippet.\(session.id.uuidString)"
                                                )
                                        } else {
                                            Text(
                                                SessionListPresentation.updatedTimestamp(
                                                    for: session.updatedAt,
                                                    localizesRelativeTerms: true
                                                )
                                            )
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 4)
                                }
                                .contentShape(Rectangle())
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isStreaming)
                            .accessibilityIdentifier(
                                "chat.search.result.\(session.id.uuidString)"
                            )
                            .accessibilityLabel(
                                result.snippet.map { "Chat \(session.title), \($0)" }
                                    ?? "Chat \(session.title)"
                            )
                            .accessibilityAddTraits(
                                viewModel.selectedSessionID == session.id
                                    ? .isSelected
                                    : []
                            )

                            if hoveredSessionID == session.id
                                || viewModel.selectedSessionID == session.id {
                                Button {
                                    Task { await viewModel.deleteSession(session.id) }
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                        .frame(width: 22, height: 22)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("Delete chat")
                                .accessibilityLabel("Delete chat \(session.title)")
                                .disabled(viewModel.isStreaming)
                            }
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .background(
                            viewModel.selectedSessionID == session.id
                                ? Color.accentColor.opacity(0.16)
                                : hoveredSessionID == session.id
                                    ? Color.secondary.opacity(0.08)
                                    : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .onHover { hovering in
                            hoveredSessionID = hovering ? session.id : nil
                        }
                        .contextMenu {
                            Button("Rename") {
                                renameSessionID = session.id
                                renameText = session.title
                            }
                            Button("Delete", role: .destructive) {
                                Task { await viewModel.deleteSession(session.id) }
                            }
                            .disabled(viewModel.isStreaming)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }

            Divider()
            if let error = viewModel.sessionErrorMessage {
                Text(error)
                    .accessibilityIdentifier("chat.session.error")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 9)
            }
            if !viewModel.statusMessage.isEmpty {
                Text(viewModel.statusMessage)
                    .accessibilityIdentifier("chat.status")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 9)
            }

            HStack(spacing: 6) {
                Button {
                    showMemories = true
                } label: {
                    Label("Memory", systemImage: "brain")
                }
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct ModelStatusPopover: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                statusIcon
                VStack(alignment: .leading, spacing: 3) {
                    Text("Local model status")
                        .font(.headline)
                    Text(statusTitle)
                        .font(.callout.weight(.medium))
                }
            }

            Text(statusDetail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Model", selection: $viewModel.selectedModel) {
                ForEach(viewModel.models) { model in
                    Text(model.name).tag(model.name)
                }
            }
            .disabled(viewModel.models.isEmpty || viewModel.isStreaming || isChecking)
            .accessibilityIdentifier("model-status.picker")

            HStack {
                Text(modelCountLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Recheck", systemImage: "arrow.clockwise") {
                    Task { await viewModel.refreshModels() }
                }
                .disabled(isChecking || viewModel.isStreaming)
                .accessibilityIdentifier("model-status.recheck")
            }
        }
        .padding(16)
        .frame(width: 330)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("model-status.popover")
    }

    @ViewBuilder
    private var statusIcon: some View {
        if isChecking {
            ProgressView()
                .controlSize(.small)
                .frame(width: 24, height: 24)
        } else {
            Image(systemName: viewModel.ollamaReadiness.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(viewModel.ollamaReadiness.isReady ? .green : .orange)
                .frame(width: 24, height: 24)
        }
    }

    private var isChecking: Bool {
        if case .checking = viewModel.ollamaReadiness { return true }
        return false
    }

    private var statusTitle: String {
        switch viewModel.ollamaReadiness {
        case .checking:
            String(localized: "Checking local Ollama")
        case .notInstalled:
            String(localized: "Ollama is not installed")
        case .serviceUnavailable:
            String(localized: "Ollama is not running")
        case .updateRequired:
            String(localized: "Ollama needs an update")
        case .modelMissing:
            String(localized: "No local models installed")
        case .ready:
            String(localized: "Local model is ready")
        }
    }

    private var statusDetail: String {
        switch viewModel.ollamaReadiness {
        case .checking:
            String(localized: "Contacting Ollama on this Mac.")
        case .notInstalled:
            String(localized: "Install Ollama from its official download page. Recovery actions are available above the conversation.")
        case .serviceUnavailable:
            String(localized: "Open the Ollama app, then recheck. Recovery actions are available above the conversation.")
        case .updateRequired(let installedVersion):
            String(localized: "Installed version: \(installedVersion). Update Ollama to continue using local models.")
        case .modelMissing:
            String(localized: "Install any Ollama model, then recheck. A recommended model command is shown above the conversation.")
        case .ready(let version):
            String(localized: "Ollama \(version) is using \(viewModel.selectedModel). Inference runs locally on this Mac.")
        }
    }

    private var modelCountLabel: String {
        let count = viewModel.models.count
        return count == 1
            ? String(localized: "1 installed model")
            : String(localized: "\(count) installed models")
    }
}

private struct AgentActivityBand: View {
    let activity: ToolActivity

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.runningLabel)
                    .font(.callout.weight(.medium))
                HStack(spacing: 5) {
                    Text(activity.inputSummary)
                    if let reason = activity.reason, !reason.isEmpty {
                        Text("·")
                        Text(reason)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.accentColor.opacity(0.07))
        .accessibilityIdentifier("agent.activity")
    }
}

private struct OllamaSetupBand: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if case .modelMissing = viewModel.ollamaReadiness {
                    Text(OllamaClient.pullCommand)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 16)
            actions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("setup.ollama")
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            switch viewModel.ollamaReadiness {
            case .checking:
                ProgressView()
                    .controlSize(.small)
            case .notInstalled:
                Button("Official Download", systemImage: "arrow.up.right.square") {
                    viewModel.openOllamaDownloadPage()
                }
                .accessibilityIdentifier("setup.ollama.download")
                recheckButton
            case .serviceUnavailable:
                Button("Open Ollama", systemImage: "play.fill") {
                    viewModel.openInstalledOllama()
                }
                .accessibilityIdentifier("setup.ollama.open")
                recheckButton
            case .updateRequired:
                Button("Official Update", systemImage: "arrow.up.right.square") {
                    viewModel.openOllamaDownloadPage()
                }
                .accessibilityIdentifier("setup.ollama.update")
                recheckButton
            case .modelMissing:
                Button("Copy Pull Command", systemImage: "doc.on.doc") {
                    viewModel.copyModelPullCommand()
                }
                .accessibilityIdentifier("setup.ollama.copy-command")
                Button("Model Page", systemImage: "arrow.up.right.square") {
                    viewModel.openRecommendedModelPage()
                }
                .accessibilityIdentifier("setup.ollama.model-page")
                recheckButton
            case .ready:
                EmptyView()
            }
        }
        .buttonStyle(.bordered)
    }

    private var recheckButton: some View {
        Button("Recheck", systemImage: "arrow.clockwise") {
            Task { await viewModel.refreshModels() }
        }
        .accessibilityIdentifier("setup.ollama.recheck")
    }

    private var icon: String {
        switch viewModel.ollamaReadiness {
        case .checking: "hourglass"
        case .notInstalled: "square.and.arrow.down"
        case .serviceUnavailable: "play.circle"
        case .updateRequired: "arrow.triangle.2.circlepath"
        case .modelMissing: "externaldrive.badge.plus"
        case .ready: "checkmark.circle.fill"
        }
    }

    private var title: String {
        switch viewModel.ollamaReadiness {
        case .checking: String(localized: "Checking local Ollama")
        case .notInstalled: String(localized: "Install Ollama from the official site")
        case .serviceUnavailable: String(localized: "Start the installed Ollama app")
        case .updateRequired: String(localized: "Update Ollama")
        case .modelMissing: String(localized: "Add an Ollama model")
        case .ready: String(localized: "Local model ready")
        }
    }

    private var detail: String {
        switch viewModel.ollamaReadiness {
        case .checking:
            return String(localized: "PrivateAI is checking the loopback service and installed models.")
        case .notInstalled:
            return String(localized: "Ollama requires macOS 14 or newer. PrivateAI opens ollama.com and never installs software for you.")
        case .serviceUnavailable:
            return String(localized: "Ollama is installed but its local service is not reachable. Open it, then return here.")
        case .updateRequired(let version):
            return String(localized: "Installed version \(version); PrivateAI requires \(OllamaClient.minimumVersion) or newer.")
        case .modelMissing(let availableDiskBytes):
            let modelSize = ByteCountFormatter.string(
                fromByteCount: OllamaClient.recommendedModelSizeBytes,
                countStyle: .file
            )
            let disk = availableDiskBytes.map {
                ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
            } ?? String(localized: "unknown")
            return String(localized: "Install any Ollama model. The recommended Qwen command below downloads about \(modelSize); available disk: \(disk).")
        case .ready(let version):
            return String(localized: "Ollama \(version) is serving \(viewModel.selectedModel) locally.")
        }
    }
}

private struct PerformanceBanner: View {
    let stats: PerformanceStats
    let selectedModel: String
    let isStreaming: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            metricsRow(compact: false)
            metricsRow(compact: true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private func metricsRow(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 15) {
            Label(
                stats.model.isEmpty ? selectedModel : stats.model,
                systemImage: "cpu"
            )
                .lineLimit(1)
            if !compact {
                Text(
                    stats.thinkingEnabled
                        ? String(localized: "Thinking")
                        : String(localized: "Fast")
                )
                metric(
                    String(localized: "TTFT"),
                    stats.ttftSeconds.map { String(format: "%.2fs", $0) } ?? "—"
                )
            }
            metric(
                compact ? "" : String(localized: "Speed"),
                String(format: "%.1f tok/s", isStreaming ? stats.tokensPerSecond : 0.0)
            )
            if !compact {
                metric(String(localized: "Prompt"), "\(stats.promptTokens)")
                metric(String(localized: "Output"), "\(stats.outputTokens)")
                metric(
                    String(localized: "Context"),
                    "~\(stats.contextEstimate) / \(stats.contextWindow)"
                )
                if stats.compactedTurns > 0 || stats.omittedTurns > 0 {
                    Text(
                        "\(stats.compactedTurns) compacted · \(stats.omittedTurns) omitted"
                    )
                    .help("Older turns were reduced to stay within the local model context window.")
                }
            }
            Spacer(minLength: 0)
            if isStreaming {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private func metric(_ name: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            if !name.isEmpty {
                Text(name)
            }
            Text(value)
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
    }
}

private struct ConversationView: View {
    @ObservedObject var viewModel: ChatViewModel

    var body: some View {
        ConversationWebView(
            messages: viewModel.currentSession?.messages ?? [],
            transcriptRevision: viewModel.transcriptRevision,
            isActive: viewModel.isStreaming,
            scrollAnchorMessageID: viewModel.requestedScrollMessageID,
            scrollRequestID: viewModel.requestedScrollRequestID,
            onAction: { action in
                switch action.kind {
                case .edit:
                    viewModel.beginEditAndResend(action.messageID)
                case .retry:
                    viewModel.retryAssistant(action.messageID)
                case .regenerate:
                    viewModel.regenerateAssistant(action.messageID)
                }
            }
        )
    }
}

private struct ComposerArea: View {
    @ObservedObject var viewModel: ChatViewModel
    @State private var showFileImporter = false
    @State private var fileImporterDeliveredResult = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let edit = viewModel.editAndResendSource {
                HStack(spacing: 8) {
                    Image(systemName: "pencil.line")
                    Text("Editing from \(edit.parentTitle). Sending creates a new chat; the original stays unchanged.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button("Cancel", systemImage: "xmark") {
                        viewModel.cancelEditAndResend()
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("chat.edit.cancel")
                }
                .accessibilityIdentifier("chat.edit.banner")
            }
            if let request = viewModel.pendingLocalFileAuthorization {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.doc")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Grant access with macOS")
                            .font(.callout.weight(.medium))
                        Text(
                            "PrivateAI cannot open a path typed in chat. Choose \(request.displayNames.joined(separator: ", ")) to grant read access."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    }
                    Spacer()
                    Button("Cancel") {
                        viewModel.cancelLocalFileAuthorization()
                    }
                    Button("Choose File", systemImage: "folder") {
                        fileImporterDeliveredResult = false
                        showFileImporter = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(9)
                .background(Color.accentColor.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .accessibilityIdentifier("chat.file-authorization")
            }
            if !viewModel.draftAttachments.isEmpty
                || !viewModel.pendingAttachmentImports.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        ForEach(viewModel.draftAttachments) { attachment in
                            AttachmentChip(
                                attachment: attachment,
                                onRemove: {
                                    viewModel.removeDraftAttachment(attachment.id)
                                }
                            )
                        }
                        ForEach(viewModel.pendingAttachmentImports) { pending in
                            PendingAttachmentChip(pending: pending)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .accessibilityIdentifier("chat.attachments")
            }
            if let error = viewModel.attachmentErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("chat.attachment.error")
            }
            NativeComposerView(
                text: $viewModel.composerText,
                focusRequestID: viewModel.composerFocusRequestID,
                onFocusRequestHandled: viewModel.acknowledgeComposerFocus,
                onPasteFiles: { urls in
                    Task { await viewModel.handleUserSelectedFiles(urls) }
                },
                onSend: viewModel.send
            )
            .frame(minHeight: 72, idealHeight: 86, maxHeight: 150)
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.25))
            }

            HStack {
                Button {
                    fileImporterDeliveredResult = false
                    showFileImporter = true
                } label: {
                    Image(systemName: "paperclip")
                }
                .buttonStyle(.borderless)
                .help("Attach a local file")
                .accessibilityLabel("Attach file")
                .accessibilityIdentifier("chat.attach")
                .disabled(viewModel.isStreaming)

                Text("Enter to send • Shift+Enter for a newline")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if viewModel.isStreaming {
                    Button("Stop", systemImage: "stop.fill") {
                        viewModel.stop()
                    }
                    .accessibilityIdentifier("chat.stop")
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Button(
                        viewModel.editAndResendSource == nil
                            ? String(localized: "Send")
                            : String(localized: "Send in new chat"),
                        systemImage: "arrow.up"
                    ) {
                        viewModel.send()
                    }
                    .accessibilityIdentifier("chat.send")
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.canSend)
                }
            }
        }
        .padding(12)
        .background(.bar)
        .dropDestination(for: URL.self) { urls, _ in
            Task { await viewModel.handleUserSelectedFiles(urls) }
            return !urls.isEmpty
        }
        .onChange(of: viewModel.pendingLocalFileAuthorization?.id) { _, requestID in
            if requestID != nil {
                fileImporterDeliveredResult = false
                showFileImporter = true
            }
        }
        .onChange(of: showFileImporter) { wasPresented, isPresented in
            guard wasPresented, !isPresented else { return }
            Task { @MainActor in
                await Task.yield()
                if !fileImporterDeliveredResult,
                   viewModel.pendingLocalFileAuthorization != nil {
                    viewModel.cancelLocalFileAuthorization()
                }
                fileImporterDeliveredResult = false
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            fileImporterDeliveredResult = true
            switch result {
            case .success(let urls):
                Task { await viewModel.handleUserSelectedFiles(urls) }
            case .failure:
                if viewModel.pendingLocalFileAuthorization != nil {
                    viewModel.cancelLocalFileAuthorization()
                }
            }
        }
    }
}

private struct PendingAttachmentChip: View {
    let pending: PendingAttachmentImport

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.badge.clock")
            VStack(alignment: .leading, spacing: 1) {
                Text(pending.displayName)
                    .lineLimit(1)
                Text("Adding locally")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("attachment.pending.\(pending.id.uuidString)")
    }
}

private struct AttachmentChip: View {
    let attachment: AttachmentReference
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.displayName)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(
                        attachment.state == .advancedParserRequired
                            ? .orange
                            : .secondary
                    )
            }
            if attachment.state == .advancedParserRequired {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help(attachment.issue?.message ?? "No extractable text")
            }
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Remove attachment")
            .accessibilityLabel("Remove \(attachment.displayName)")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("attachment.\(attachment.id.uuidString)")
    }

    private var detail: String {
        if attachment.state == .failed {
            return attachment.issue?.message
                ?? String(localized: "Attachment unavailable")
        }
        if attachment.state == .advancedParserRequired {
            return String(localized: "No extractable text")
        }
        if let pageCount = attachment.artifact?.pageCount,
           attachment.kind == .pdf {
            let parser = attachment.artifact?.parserID ?? "local"
            return String(localized: "\(pageCount) pages · \(parser)")
        }
        if attachment.kind == .text {
            let chunks = attachment.artifact?.chunkCount ?? 0
            return String(localized: "\(chunks) sections · native text")
        }
        return ByteCountFormatter.string(
            fromByteCount: attachment.byteCount,
            countStyle: .file
        )
    }

    private var icon: String {
        switch attachment.kind {
        case .pdf: "doc.richtext"
        case .image: "photo"
        case .text: "doc.text"
        }
    }
}

private struct SettingsSheet: View {
    @ObservedObject var viewModel: ChatViewModel
    @Binding var isPresented: Bool
    @State private var showPrivacy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings")
                .font(.title2.weight(.semibold))
            Form {
                Toggle("Thinking mode", isOn: $viewModel.thinkingEnabled)
                LabeledContent("Inference") {
                    Text("Local Ollama")
                }
                LabeledContent("Model") {
                    Text(
                        viewModel.selectedModel.isEmpty
                            ? String(localized: "None selected")
                            : viewModel.selectedModel
                    )
                }
                Text(
                    viewModel.thinkingEnabled
                        ? String(localized: "Ollama receives think:true. Thinking appears only when the model streams real thinking text.")
                        : String(localized: "Fast mode sends think:false.")
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Button {
                    showPrivacy = true
                } label: {
                    Label("Privacy & Data", systemImage: "hand.raised")
                }
                .accessibilityIdentifier("settings.privacy")
            }
            HStack {
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 520)
        .sheet(isPresented: $showPrivacy) {
            PrivacyDataSheet(isPresented: $showPrivacy)
        }
    }
}

private struct PrivacyDataSheet: View {
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Privacy & Data")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(22)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    privacySection(
                        title: "Local by design",
                        icon: "macbook",
                        text: "Core chat and document analysis are sent only to the Ollama service on this Mac. PrivateAI has no account, advertising, analytics, or cloud-model fallback."
                    )
                    privacySection(
                        title: "Data stored on this Mac",
                        icon: "internaldrive",
                        text: "Chats, memories, logs, imported file copies, extracted text, and local model profiles stay in PrivateAI's sandbox container. Deleting a chat does not delete its Library documents."
                    )
                    privacySection(
                        title: "When PrivateAI uses the network",
                        icon: "network",
                        text: "When a task needs current information, PrivateAI may send a search query to DuckDuckGo or fetch a website you requested. Nearby searches use your location only after your request authorizes it. These actions are shown in the conversation."
                    )
                    privacySection(
                        title: "Your controls",
                        icon: "slider.horizontal.3",
                        text: "You choose files through macOS. Delete chats from the sidebar, delete memories from Memories, and permanently remove stored document data from the Document Library."
                    )

                    if let url = AppReleaseInformation.privacyPolicyURL {
                        Link(destination: url) {
                            Label("Open Online Privacy Policy", systemImage: "arrow.up.right.square")
                        }
                        .accessibilityIdentifier("privacy.online-policy")
                    }
                }
                .padding(22)
            }
        }
        .frame(width: 620, height: 560)
        .accessibilityIdentifier("privacy.sheet")
    }

    private func privacySection(
        title: LocalizedStringKey,
        icon: String,
        text: LocalizedStringKey
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct MemorySheet: View {
    @ObservedObject var viewModel: ChatViewModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Local Memories")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
            Text("Short durable summaries generated locally after chat becomes idle.")
                .foregroundStyle(.secondary)
            if viewModel.memories.isEmpty {
                ContentUnavailableView(
                    "No memories",
                    systemImage: "brain",
                    description: Text("Useful durable details will appear here.")
                )
            } else {
                List(viewModel.memories) { memory in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(memory.summary)
                                .textSelection(.enabled)
                            Text(memory.createdAt, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            viewModel.deleteMemory(memory.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(22)
        .frame(minWidth: 600, minHeight: 420)
        .task { await viewModel.reloadMemories() }
    }
}

private struct DocumentLibrarySheet: View {
    @ObservedObject var viewModel: ChatViewModel
    @Binding var isPresented: Bool
    @State private var searchText = ""
    @State private var pendingDeletion: DocumentLibraryRecord?

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoadingLibrary && viewModel.libraryDocuments.isEmpty {
                    ProgressView("Opening Library")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = viewModel.libraryErrorMessage,
                          viewModel.libraryDocuments.isEmpty {
                    ContentUnavailableView(
                        "Library unavailable",
                        systemImage: "externaldrive.badge.exclamationmark",
                        description: Text(error)
                    )
                } else if viewModel.libraryDocuments.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "No documents" : "No matches",
                        systemImage: searchText.isEmpty
                            ? "books.vertical"
                            : "magnifyingglass",
                        description: Text(
                            searchText.isEmpty
                                ? "Documents appear after you attach them to a chat."
                                : "Try another filename or phrase."
                        )
                    )
                } else {
                    VStack(spacing: 0) {
                        if let error = viewModel.libraryErrorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .accessibilityIdentifier("library.error")
                            Divider()
                        }
                        List(viewModel.libraryDocuments) { document in
                            LibraryDocumentRow(
                                document: document,
                                profile: viewModel.libraryProfiles[document.id],
                                isAdded: viewModel.draftAttachments.contains {
                                    $0.sha256 == document.reference.sha256
                                },
                                canEditDraft: !viewModel.isStreaming,
                                onAdd: {
                                    Task {
                                        await viewModel.addLibraryDocumentToDraft(document)
                                    }
                                },
                                onAnalyze: {
                                    Task {
                                        await viewModel.analyzeLibraryDocument(document)
                                    }
                                },
                                onDelete: {
                                    pendingDeletion = document
                                }
                            )
                        }
                        .listStyle(.inset)
                    }
                }
            }
            .navigationTitle("Document Library")
            .searchable(
                text: $searchText,
                placement: .toolbar,
                prompt: "Search files and contents"
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { isPresented = false }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .frame(minWidth: 680, minHeight: 500)
        .task(id: searchText) {
            await viewModel.reloadLibrary(matching: searchText)
        }
        .alert(
            "Delete from Library?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { document in
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
            Button("Delete", role: .destructive) {
                pendingDeletion = nil
                Task { await viewModel.deleteDocumentFromLibrary(document) }
            }
        } message: { document in
            Text(
                "This permanently removes \(document.reference.displayName), its extracted text, and local Qwen profiles. Past chats keep only the file reference."
            )
        }
    }
}

private struct LibraryDocumentRow: View {
    let document: DocumentLibraryRecord
    let profile: DocumentProfile?
    let isAdded: Bool
    let canEditDraft: Bool
    let onAdd: () -> Void
    let onAnalyze: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(document.reference.displayName)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(document.importedAt, style: .date)
                    Text(
                        ByteCountFormatter.string(
                            fromByteCount: document.reference.byteCount,
                            countStyle: .file
                        )
                    )
                    if profile != nil {
                        Label("Qwen profile", systemImage: "sparkles")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let profile {
                    Text(profile.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 12)
            if profile == nil {
                Button(action: onAnalyze) {
                    Image(systemName: "sparkles")
                }
                .buttonStyle(.borderless)
                .disabled(!canEditDraft)
                .help("Create local Qwen profile")
                .accessibilityLabel(
                    "Create Qwen profile for \(document.reference.displayName)"
                )
            }
            Button(action: onAdd) {
                Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle")
            }
            .buttonStyle(.borderless)
            .disabled(isAdded || !canEditDraft || document.reference.state != .ready)
            .help(isAdded ? "Already attached" : "Add to chat")
            .accessibilityLabel(
                isAdded
                    ? "\(document.reference.displayName) already attached"
                    : "Add \(document.reference.displayName) to chat"
            )

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(!canEditDraft)
            .help("Delete from Library")
            .accessibilityLabel("Delete \(document.reference.displayName) from Library")
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.document.\(document.id.uuidString)")
    }

    private var icon: String {
        switch document.reference.kind {
        case .pdf: "doc.richtext"
        case .image: "photo"
        case .text: "doc.text"
        }
    }
}
