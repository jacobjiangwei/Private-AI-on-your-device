import AppKit
import SwiftUI

public struct NativeComposerView: NSViewRepresentable {
    @Binding var text: String
    let focusRequestID: UUID?
    let onFocusRequestHandled: (UUID) -> Void
    let onPasteFiles: ([URL]) -> Void
    let onSend: () -> Void

    public init(
        text: Binding<String>,
        focusRequestID: UUID? = nil,
        onFocusRequestHandled: @escaping (UUID) -> Void = { _ in },
        onPasteFiles: @escaping ([URL]) -> Void = { _ in },
        onSend: @escaping () -> Void
    ) {
        self._text = text
        self.focusRequestID = focusRequestID
        self.onFocusRequestHandled = onFocusRequestHandled
        self.onPasteFiles = onPasteFiles
        self.onSend = onSend
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.setAccessibilityIdentifier("chat.composer.container")

        let textView = SendingTextView()
        textView.delegate = context.coordinator
        textView.onSend = onSend
        textView.onPasteFiles = onPasteFiles
        textView.onFocusRequestHandled = onFocusRequestHandled
        textView.requestFocus(focusRequestID)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 9, height: 9)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        textView.setAccessibilityIdentifier("chat.composer")
        textView.setAccessibilityLabel(String(localized: "Message"))
        scrollView.documentView = textView
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SendingTextView else { return }
        textView.onSend = onSend
        textView.onPasteFiles = onPasteFiles
        textView.onFocusRequestHandled = onFocusRequestHandled
        textView.requestFocus(focusRequestID)
        if textView.string != text {
            let isFocused = textView.window?.firstResponder === textView
            if isFocused, !text.isEmpty {
                // SwiftUI transcript updates may arrive before the latest native
                // edit propagates through the binding. Never overwrite active
                // composition/cursor state with that stale value.
                context.coordinator.parent = self
                return
            }
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(
                NSRange(location: min(selection.location, text.utf16.count), length: 0)
            )
        }
        context.coordinator.parent = self
    }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeComposerView

        init(parent: NativeComposerView) {
            self.parent = parent
        }

        public func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let value = textView.string
            if parent.text != value {
                parent.text = value
            }
        }
    }
}

final class SendingTextView: NSTextView {
    var onSend: (() -> Void)?
    var onPasteFiles: (([URL]) -> Void)?
    var onFocusRequestHandled: ((UUID) -> Void)?
    private var requestedFocusID: UUID?
    private var handledFocusID: UUID?
    private var focusRetryCount = 0
    private var scheduledFocusRetryID: UUID?

    func requestFocus(_ requestID: UUID?) {
        if requestID != requestedFocusID {
            focusRetryCount = 0
            scheduledFocusRetryID = nil
        }
        requestedFocusID = requestID
        applyFocusRequestIfPossible()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyFocusRequestIfPossible()
    }

    private func applyFocusRequestIfPossible() {
        guard let requestedFocusID,
              requestedFocusID != handledFocusID,
              let window
        else { return }
        guard window.makeFirstResponder(self) else {
            scheduleFocusRetry(requestedFocusID)
            return
        }
        setSelectedRange(NSRange(location: string.utf16.count, length: 0))
        handledFocusID = requestedFocusID
        focusRetryCount = 0
        scheduledFocusRetryID = nil
        DispatchQueue.main.async { [weak self] in
            self?.onFocusRequestHandled?(requestedFocusID)
        }
    }

    private func scheduleFocusRetry(_ requestID: UUID) {
        guard focusRetryCount < 3,
              scheduledFocusRetryID != requestID
        else { return }
        focusRetryCount += 1
        scheduledFocusRetryID = requestID
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.requestedFocusID == requestID,
                  self.handledFocusID != requestID
            else { return }
            self.scheduledFocusRetryID = nil
            self.applyFocusRequestIfPossible()
        }
    }

    override func paste(_ sender: Any?) {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let urls = (NSPasteboard.general.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) as? [NSURL])?.compactMap { $0 as URL? }.filter(\.isFileURL) ?? []
        guard !urls.isEmpty else {
            super.paste(sender)
            return
        }
        onPasteFiles?(urls)
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn,
           !event.modifierFlags.contains(.shift),
           !hasMarkedText() {
            onSend?()
            return
        }
        super.keyDown(with: event)
    }
}
