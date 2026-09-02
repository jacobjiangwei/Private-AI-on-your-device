import Foundation
import SwiftUI
@preconcurrency import WebKit

struct TranscriptWebView: NSViewRepresentable {
    let messages: [MessageRecord]
  let revision: Int
    let onCopy: (UUID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCopy: onCopy)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "copyMessage")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setAccessibilityIdentifier("chat.transcript")
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        webView.loadHTMLString(Self.document, baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
      _ = revision
        context.coordinator.onCopy = onCopy
        context.coordinator.render(messages)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "copyMessage")
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var onCopy: (UUID) -> Void
        private var isReady = false
        private var pendingMessages: [MessageRecord] = []

        init(onCopy: @escaping (UUID) -> Void) {
            self.onCopy = onCopy
        }

        func render(_ messages: [MessageRecord]) {
            pendingMessages = messages
            guard isReady, let webView else { return }
            let payload: [[String: Any]] = messages.map {
                [
                    "id": $0.id.uuidString,
                    "role": $0.role.rawValue,
                    "content": $0.content,
                    "status": $0.status.rawValue,
                    "error": $0.errorMessage ?? "",
                "tool": $0.toolName ?? "",
                "attachments": $0.attachments
                  .sorted { $0.sortOrder < $1.sortOrder }
                  .compactMap { attachment -> [String: Any]? in
                    guard let blob = attachment.blob else { return nil }
                    return [
                      "name": attachment.displayName,
                      "format": blob.formatRawValue,
                      "size": blob.byteCount
                    ]
                  }
                ]
            }
            Task { @MainActor in
              _ = try? await webView.callAsyncJavaScript(
                "render(messages)",
                arguments: ["messages": payload],
                in: nil,
                contentWorld: .page
              )
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isReady = true
            render(pendingMessages)
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let rawID = message.body as? String, let id = UUID(uuidString: rawID) else { return }
          onCopy(id)
        }
    }

    private static let document = #"""
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'nonce-privateai'; script-src 'nonce-privateai'; img-src data:">
      <style nonce="privateai">
        :root { color-scheme: light dark; font-family: ui-rounded, "Avenir Next", sans-serif; }
        * { box-sizing: border-box; }
        body { margin: 0; background: transparent; color: CanvasText; }
        #messages { max-width: 860px; margin: 0 auto; padding: 24px 28px 48px; }
        article { position: relative; margin: 0 0 22px; padding-right: 34px; }
        article.user { margin-left: 18%; padding: 12px 42px 12px 14px; background: color-mix(in srgb, AccentColor 14%, Canvas); border-radius: 8px; }
        .attachments { display: flex; flex-wrap: wrap; gap: 6px; margin-bottom: 8px; }
        .attachment { min-width: 0; max-width: 100%; padding: 5px 8px; border: 1px solid color-mix(in srgb, GrayText 30%, transparent); border-radius: 6px; color: GrayText; font-size: 11px; overflow-wrap: anywhere; }
        article.tool { border: 1px solid color-mix(in srgb, GrayText 28%, transparent); border-left: 3px solid GrayText; padding: 12px 42px 12px 14px; border-radius: 6px; color: GrayText; font-size: 12px; }
        article.tool .content { font-family: ui-monospace, monospace; line-height: 1.45; }
        article.tool .content p { margin: .35em 0; }
        article.tool .content pre { max-height: 240px; margin: 8px 0; }
        article.thinking { padding: 0 42px 0 0; color: GrayText; font-size: 13px; }
        article.thinking .thinking-title { display: flex; align-items: center; gap: 8px; font-weight: 600; margin-bottom: 8px; }
        article.thinking .thinking-body { border-left: 2px solid color-mix(in srgb, GrayText 40%, transparent); padding: 8px 12px; }
        article.thinking .content { margin-top: 8px; font-size: 12px; line-height: 1.5; }
        .thinking-glow {
          background: linear-gradient(90deg,
            color-mix(in srgb, GrayText 55%, transparent) 0%,
            color-mix(in srgb, AccentColor 90%, CanvasText) 50%,
            color-mix(in srgb, GrayText 55%, transparent) 100%);
          background-size: 200% 100%;
          -webkit-background-clip: text; background-clip: text; color: transparent;
          animation: shimmer 2s linear infinite;
        }
        .dots { display: inline-flex; gap: 3px; align-items: flex-end; }
        .dots span {
          width: 5px; height: 5px; border-radius: 50%;
          background: color-mix(in srgb, AccentColor 85%, CanvasText);
          animation: bounce 1.3s ease-in-out infinite;
        }
        .dots span:nth-child(2) { animation-delay: .16s; }
        .dots span:nth-child(3) { animation-delay: .32s; }
        @keyframes shimmer { to { background-position: -200% 0; } }
        @keyframes bounce {
          0%, 60%, 100% { transform: translateY(0); opacity: .45; }
          30% { transform: translateY(-5px); opacity: 1; }
        }
        .copy { position: absolute; right: 4px; top: 4px; border: 0; background: transparent; color: GrayText; cursor: pointer; font-size: 15px; }
        .content { line-height: 1.6; overflow-wrap: anywhere; }
        .content h1, .content h2, .content h3 { line-height: 1.25; margin: 1.1em 0 .45em; letter-spacing: 0; }
        .content h1 { font-size: 24px; } .content h2 { font-size: 20px; } .content h3 { font-size: 17px; }
        .content p { margin: .55em 0; }
        .content pre { padding: 13px; overflow: auto; border-radius: 6px; background: color-mix(in srgb, CanvasText 8%, Canvas); }
        .content code { font-family: ui-monospace, "SFMono-Regular", monospace; font-size: .9em; }
        .content :not(pre) > code { padding: 2px 5px; border-radius: 4px; background: color-mix(in srgb, CanvasText 8%, Canvas); }
        .content blockquote { margin-left: 0; padding-left: 14px; border-left: 3px solid GrayText; color: GrayText; }
        .content a { color: LinkText; }
        .content table { width: 100%; margin: .8em 0; border-collapse: collapse; display: block; overflow-x: auto; }
        .content th, .content td { padding: 8px 10px; border: 1px solid color-mix(in srgb, GrayText 35%, transparent); text-align: left; white-space: nowrap; }
        .content th { font-weight: 600; background: color-mix(in srgb, CanvasText 7%, Canvas); }
        .error { color: #c43b32; font-size: 12px; margin-top: 6px; }
        .sr-only { position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px; overflow: hidden; clip: rect(0, 0, 0, 0); white-space: nowrap; border: 0; }
        .streaming::after {
          content: ""; display: inline-block; width: 2px; height: 1.05em; margin-left: 3px;
          border-radius: 2px; background: color-mix(in srgb, CanvasText 45%, transparent);
          vertical-align: text-bottom; animation: caret 1.1s ease-in-out infinite;
        }
        /* When a streaming bubble has real text, show a subtle thin caret; the empty
           "waiting for first token" state uses the .dots indicator instead (see JS). */
        .content.streaming.waiting::after { content: none; }
        @keyframes caret {
          0%, 100% { opacity: .85; }
          50% { opacity: .15; }
        }
        @media (prefers-reduced-motion: reduce) {
          .streaming::after { animation: none; opacity: 1; }
          .thinking-glow { animation: none; }
          .dots span { animation: none; opacity: .7; }
        }
      </style>
    </head>
    <body><main id="messages"></main><div id="scroll-status" class="sr-only" role="status">Transcript ready</div>
      <script nonce="privateai">
        const escapeHTML = value => String(value)
          .replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
          .replaceAll('"', '&quot;').replaceAll("'", '&#039;');
        function inline(value) {
          return escapeHTML(value)
            .replace(/`([^`]+)`/g, '<code>$1</code>')
            .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
            .replace(/\*([^*]+)\*/g, '<em>$1</em>')
            .replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g, '<a href="$2">$1</a>');
        }
        function tableCells(line) {
          const trimmed = line.trim().replace(/^\|/, '').replace(/\|$/, '');
          return trimmed.split('|').map(cell => cell.trim());
        }
        function isTableDivider(line) {
          const cells = tableCells(line);
          return cells.length > 0 && cells.every(cell => /^:?-{3,}:?$/.test(cell));
        }
        function markdown(source) {
          const lines = String(source).split('\n');
          let html = '', paragraph = [], inCode = false, code = [];
          const flush = () => { if (paragraph.length) { html += '<p>' + inline(paragraph.join(' ')) + '</p>'; paragraph = []; } };
          for (let index = 0; index < lines.length; index++) {
            const line = lines[index];
            if (line.startsWith('```')) {
              flush();
              if (inCode) { html += '<pre><code>' + escapeHTML(code.join('\n')) + '</code></pre>'; code = []; }
              inCode = !inCode; continue;
            }
            if (inCode) { code.push(line); continue; }
            if (line.includes('|') && index + 1 < lines.length && isTableDivider(lines[index + 1])) {
              flush();
              const headers = tableCells(line);
              index += 2;
              const rows = [];
              while (index < lines.length && lines[index].includes('|') && lines[index].trim()) {
                rows.push(tableCells(lines[index]));
                index += 1;
              }
              index -= 1;
              html += '<table><thead><tr>' + headers.map(cell => '<th>' + inline(cell) + '</th>').join('') + '</tr></thead>';
              html += '<tbody>' + rows.map(row => '<tr>' + headers.map((_, cellIndex) => '<td>' + inline(row[cellIndex] || '') + '</td>').join('') + '</tr>').join('') + '</tbody></table>';
              continue;
            }
            const heading = line.match(/^(#{1,3})\s+(.+)$/);
            if (heading) { flush(); const level = heading[1].length; html += `<h${level}>${inline(heading[2])}</h${level}>`; continue; }
            if (/^[-*]\s+/.test(line)) { flush(); html += '<ul><li>' + inline(line.replace(/^[-*]\s+/, '')) + '</li></ul>'; continue; }
            if (line.startsWith('> ')) { flush(); html += '<blockquote>' + inline(line.slice(2)) + '</blockquote>'; continue; }
            if (!line.trim()) { flush(); continue; }
            paragraph.push(line);
          }
          if (inCode) { html += '<pre><code>' + escapeHTML(code.join('\n')) + '</code></pre>'; }
          flush(); return html;
        }
        function byteCount(value) {
          const bytes = Number(value) || 0;
          if (bytes < 1024) return `${bytes} B`;
          if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
          return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
        }
        function render(messages) {
          const root = document.getElementById('messages');
          root.replaceChildren(...messages.map(message => {
            const article = document.createElement('article');
            article.className = message.role;
            article.id = 'message-' + message.id;
            article.dataset.sequence = String(messages.indexOf(message));
            article.setAttribute('aria-label', message.role === 'tool'
              ? `Tool ${message.tool}, ${message.status}`
              : `${message.role} message, ${message.status}`);
            const content = document.createElement('div');
            const isStreaming = message.status === 'streaming';
            const hasText = (message.content || '').trim().length > 0;
            const isWaiting = isStreaming && !hasText && message.role !== 'thinking';
            content.className = 'content'
              + (isStreaming ? ' streaming' : '')
              + (isWaiting ? ' waiting' : '');
            if (isWaiting) {
              const dots = document.createElement('span');
              dots.className = 'dots';
              dots.innerHTML = '<span></span><span></span><span></span>';
              content.appendChild(dots);
            } else {
              content.innerHTML = markdown(message.content || '');
            }
            if (Array.isArray(message.attachments) && message.attachments.length > 0) {
              const attachments = document.createElement('div');
              attachments.className = 'attachments';
              for (const item of message.attachments) {
                const attachment = document.createElement('div');
                attachment.className = 'attachment';
                attachment.textContent = `${item.name} · ${String(item.format).replaceAll('_', ' ')} · ${byteCount(item.size)}`;
                attachments.appendChild(attachment);
              }
              article.appendChild(attachments);
            }
            if (message.role === 'thinking') {
              const body = document.createElement('div');
              body.className = 'thinking-body';
              const title = document.createElement('div');
              title.className = 'thinking-title';
              if (message.status === 'streaming') {
                const label = document.createElement('span');
                label.className = 'thinking-glow';
                label.textContent = 'Thinking';
                const dots = document.createElement('span');
                dots.className = 'dots';
                dots.innerHTML = '<span></span><span></span><span></span>';
                title.append(label, dots);
              } else {
                title.textContent = 'Thinking';
              }
              body.append(title, content);
              article.appendChild(body);
            } else {
              article.appendChild(content);
            }
            if (message.error) { const error = document.createElement('div'); error.className = 'error'; error.textContent = message.error; article.appendChild(error); }
            const copy = document.createElement('button'); copy.className = 'copy'; copy.textContent = '⧉'; copy.title = 'Copy source'; copy.onclick = () => webkit.messageHandlers.copyMessage.postMessage(message.id); article.appendChild(copy);
            return article;
          }));
          requestAnimationFrame(() => {
            window.scrollTo({ top: document.body.scrollHeight, behavior: 'instant' });
            const atBottom = Math.ceil(window.scrollY + window.innerHeight) >= document.documentElement.scrollHeight;
            document.body.dataset.scrolledToBottom = String(atBottom);
            document.getElementById('scroll-status').textContent = atBottom
              ? 'Transcript showing latest message'
              : 'Transcript not showing latest message';
          });
        }
      </script>
    </body>
    </html>
    """#
}