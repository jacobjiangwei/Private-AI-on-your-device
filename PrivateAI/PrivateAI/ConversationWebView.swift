import AppKit
import Foundation
import SwiftUI
@preconcurrency import WebKit

public struct ConversationTranscriptLocalization: Codable, Equatable, Sendable {
    public let languageCode: String
    public let labels: [String: String]

    public init(languageCode: String, labels: [String: String]) {
        self.languageCode = languageCode
        self.labels = labels
    }

    public static var current: ConversationTranscriptLocalization {
        ConversationTranscriptLocalization(
            languageCode: Locale.current.language.languageCode?.identifier ?? "en",
            labels: [
                "attachment": String(localized: "transcript.attachment", defaultValue: "Attachment"),
                "attachmentUnavailable": String(localized: "transcript.attachmentUnavailable", defaultValue: "Attachment unavailable"),
                "complete": String(localized: "transcript.complete", defaultValue: "Complete"),
                "copied": String(localized: "transcript.copied", defaultValue: "Copied"),
                "copy": String(localized: "transcript.copy", defaultValue: "Copy"),
                "copyResponse": String(localized: "transcript.copyResponse", defaultValue: "Copy response"),
                "copyableText": String(localized: "transcript.copyableText", defaultValue: "Copyable text"),
                "details": String(localized: "transcript.details", defaultValue: "Details"),
                "edit": String(localized: "transcript.edit", defaultValue: "Edit"),
                "failed": String(localized: "transcript.failed", defaultValue: "Failed"),
                "generating": String(localized: "transcript.generating", defaultValue: "Generating"),
                "image": String(localized: "transcript.image", defaultValue: "Image"),
                "localCalculation": String(localized: "transcript.localCalculation", defaultValue: "Local calculation"),
                "localContext": String(localized: "transcript.localContext", defaultValue: "Mac context"),
                "nativeText": String(localized: "transcript.nativeText", defaultValue: "native text"),
                "nearbySearch": String(localized: "transcript.nearbySearch", defaultValue: "Nearby search"),
                "noExtractableText": String(localized: "transcript.noExtractableText", defaultValue: "No extractable text"),
                "noResponse": String(localized: "transcript.noResponse", defaultValue: "No response"),
                "pages": String(localized: "transcript.pages", defaultValue: "pages"),
                "pdf": String(localized: "transcript.pdf", defaultValue: "PDF"),
                "privateConversation": String(localized: "transcript.privateConversation", defaultValue: "Private conversations with your local Ollama models."),
                "readWebpage": String(localized: "transcript.readWebpage", defaultValue: "Read webpage"),
                "regenerate": String(localized: "transcript.regenerate", defaultValue: "Regenerate"),
                "retry": String(localized: "transcript.retry", defaultValue: "Retry"),
                "running": String(localized: "transcript.running", defaultValue: "Running"),
                "sections": String(localized: "transcript.sections", defaultValue: "sections"),
                "thinking": String(localized: "transcript.thinking", defaultValue: "Thinking"),
                "tool": String(localized: "transcript.tool", defaultValue: "Tool"),
                "webSearch": String(localized: "transcript.webSearch", defaultValue: "Web search")
            ]
        )
    }
}

public struct ConversationTranscriptPayload: Codable, Equatable, Sendable {
    public let messages: [ChatMessage]
    public let transcriptRevision: Int
    public let isActive: Bool
    public let scrollAnchorMessageID: UUID?
    public let scrollRequestID: UUID?
    public let localization: ConversationTranscriptLocalization

    public init(
        messages: [ChatMessage],
        transcriptRevision: Int,
        isActive: Bool,
        scrollAnchorMessageID: UUID? = nil,
        scrollRequestID: UUID? = nil,
        localization: ConversationTranscriptLocalization = .current
    ) {
        self.messages = messages
        self.transcriptRevision = transcriptRevision
        self.isActive = isActive
        self.scrollAnchorMessageID = scrollAnchorMessageID
        self.scrollRequestID = scrollRequestID
        self.localization = localization
    }
}

public enum ConversationTranscriptEncoder {
    public static func encode(_ payload: ConversationTranscriptPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }
}

public enum TranscriptActionKind: String, Sendable {
    case edit
    case retry
    case regenerate
}

public struct TranscriptAction: Sendable {
    public let kind: TranscriptActionKind
    public let messageID: UUID

    public init(kind: TranscriptActionKind, messageID: UUID) {
        self.kind = kind
        self.messageID = messageID
    }
}

enum TranscriptWebAssets {
    static var sourceDirectoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Web", isDirectory: true)
    }

    static func availableDirectoryURL() -> URL? {
        let fileManager = FileManager.default
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("Web", isDirectory: true)
            if fileManager.fileExists(
                atPath: bundled.appendingPathComponent("transcript.html").path
            ) {
                return bundled
            }
            if fileManager.fileExists(
                atPath: resources.appendingPathComponent("transcript.html").path
            ) {
                return resources
            }
        }
        let source = sourceDirectoryURL
        if fileManager.fileExists(
            atPath: source.appendingPathComponent("transcript.html").path
        ) {
            return source
        }
        return nil
    }
}

public struct ConversationWebView: NSViewRepresentable {
    public let messages: [ChatMessage]
    public let transcriptRevision: Int
    public let isActive: Bool
    public let scrollAnchorMessageID: UUID?
    public let scrollRequestID: UUID?
    public let onAction: (@MainActor (TranscriptAction) -> Void)?

    public init(
        messages: [ChatMessage],
        transcriptRevision: Int,
        isActive: Bool,
        scrollAnchorMessageID: UUID? = nil,
        scrollRequestID: UUID? = nil,
        onAction: (@MainActor (TranscriptAction) -> Void)? = nil
    ) {
        self.messages = messages
        self.transcriptRevision = transcriptRevision
        self.isActive = isActive
        self.scrollAnchorMessageID = scrollAnchorMessageID
        self.scrollRequestID = scrollRequestID
        self.onAction = onAction
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    public func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: Coordinator.copyTextMessage)
        controller.add(context.coordinator, name: Coordinator.openExternalMessage)
        controller.add(context.coordinator, name: Coordinator.transcriptActionMessage)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsMagnification = true
        webView.underPageBackgroundColor = .clear
        webView.setAccessibilityIdentifier("chat.transcript")
        context.coordinator.attach(webView)
        context.coordinator.onAction = onAction
        context.coordinator.update(payload: payload)
        context.coordinator.loadTranscript()
        return webView
    }

    public func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onAction = onAction
        context.coordinator.update(payload: payload)
    }

    public static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: Coordinator.copyTextMessage)
        controller.removeScriptMessageHandler(forName: Coordinator.openExternalMessage)
        controller.removeScriptMessageHandler(forName: Coordinator.transcriptActionMessage)
        coordinator.detach()
    }

    private var payload: ConversationTranscriptPayload {
        ConversationTranscriptPayload(
            messages: messages,
            transcriptRevision: transcriptRevision,
            isActive: isActive,
            scrollAnchorMessageID: scrollAnchorMessageID,
            scrollRequestID: scrollRequestID
        )
    }

    @MainActor
    public final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate,
        WKScriptMessageHandler {
        fileprivate static let copyTextMessage = "copyText"
        fileprivate static let openExternalMessage = "openExternal"
        fileprivate static let transcriptActionMessage = "transcriptAction"

        private weak var webView: WKWebView?
        private var documentURL: URL?
        private var isReady = false
        private var pendingPayload: Data?
        private var lastRenderedPayload: Data?
        fileprivate var onAction: (@MainActor (TranscriptAction) -> Void)?

        fileprivate func attach(_ webView: WKWebView) {
            self.webView = webView
        }

        fileprivate func detach() {
            webView = nil
            documentURL = nil
            isReady = false
            pendingPayload = nil
            lastRenderedPayload = nil
            onAction = nil
        }

        fileprivate func loadTranscript() {
            guard let webView,
                  let directory = TranscriptWebAssets.availableDirectoryURL()
            else { return }
            let document = directory.appendingPathComponent("transcript.html")
            documentURL = document.standardizedFileURL
            webView.loadFileURL(document, allowingReadAccessTo: directory)
        }

        fileprivate func update(payload: ConversationTranscriptPayload) {
            guard let data = try? ConversationTranscriptEncoder.encode(payload),
                  data != pendingPayload,
                  data != lastRenderedPayload
            else { return }
            pendingPayload = data
            renderPendingPayload()
        }

        private func renderPendingPayload() {
            guard isReady,
                  let webView,
                  let data = pendingPayload,
                  let object = try? JSONSerialization.jsonObject(with: data)
            else { return }
            pendingPayload = nil
            lastRenderedPayload = data
            webView.callAsyncJavaScript(
                "renderConversation(payload)",
                arguments: ["payload": object],
                in: nil,
                in: .page,
                completionHandler: nil
            )
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard sameLocalDocument(webView.url) else { return }
            isReady = true
            renderPendingPayload()
        }

        public func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (
                WKNavigationActionPolicy
            ) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if sameLocalDocument(url) {
                decisionHandler(.allow)
                return
            }
            if let externalURL = validatedExternalURL(url) {
                NSWorkspace.shared.open(externalURL)
            }
            decisionHandler(.cancel)
        }

        public func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }

        public func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            switch message.name {
            case Self.copyTextMessage:
                guard let text = message.body as? String,
                      text.utf8.count <= 1_000_000
                else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            case Self.openExternalMessage:
                guard let value = message.body as? String,
                      value.utf8.count <= 8_192,
                      let url = URL(string: value),
                      let externalURL = validatedExternalURL(url)
                else { return }
                NSWorkspace.shared.open(externalURL)
            case Self.transcriptActionMessage:
                guard let body = message.body as? [String: Any],
                      let rawAction = body["action"] as? String,
                      let kind = TranscriptActionKind(rawValue: rawAction),
                      let rawMessageID = body["messageID"] as? String,
                      rawMessageID.utf8.count <= 64,
                      let messageID = UUID(uuidString: rawMessageID)
                else { return }
                onAction?(TranscriptAction(kind: kind, messageID: messageID))
            default:
                return
            }
        }

        private func sameLocalDocument(_ candidate: URL?) -> Bool {
            guard let documentURL, let candidate, candidate.isFileURL else {
                return false
            }
            return candidate.standardizedFileURL.path == documentURL.path
        }

        private func validatedExternalURL(_ url: URL) -> URL? {
            guard let components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            ),
            components.scheme == "http" || components.scheme == "https",
            components.host != nil,
            components.user == nil,
            components.password == nil
            else { return nil }
            return components.url
        }
    }
}
