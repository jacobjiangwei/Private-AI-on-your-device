(() => {
  "use strict";

  const vendors = window.TranscriptVendors;
  const transcript = document.getElementById("transcript");
  const copyTextByID = new Map();
  let renderedMessageIDs = new Set();
  let wasActive = false;
  let handledScrollRequestID = null;
  let pendingScrollTimer = null;
  let pendingScrollRequestID = null;
  const defaultLabels = {
    attachment: "Attachment",
    attachmentUnavailable: "Attachment unavailable",
    complete: "Complete",
    copied: "Copied",
    copy: "Copy",
    copyResponse: "Copy response",
    copyableText: "Copyable text",
    details: "Details",
    edit: "Edit",
    failed: "Failed",
    generating: "Generating",
    image: "Image",
    localCalculation: "Local calculation",
    localContext: "Mac context",
    nativeText: "native text",
    nearbySearch: "Nearby search",
    noExtractableText: "No extractable text",
    noResponse: "No response",
    pages: "pages",
    pdf: "PDF",
    privateConversation: "Private conversations with your local Ollama models.",
    readWebpage: "Read webpage",
    regenerate: "Regenerate",
    retry: "Retry",
    running: "Running",
    sections: "sections",
    thinking: "Thinking",
    tool: "Tool",
    webSearch: "Web search"
  };
  let labels = defaultLabels;

  const localized = (key) => labels[key] || defaultLabels[key] || key;

  const escapeHTML = (value) => vendors.markdownit().utils.escapeHtml(String(value));

  function mathPlugin(md) {
    function renderMath(source, displayMode) {
      try {
        return vendors.katex.renderToString(source, {
          displayMode,
          output: "htmlAndMathml",
          throwOnError: true,
          strict: "warn",
          trust: false
        });
      } catch {
        const delimiter = displayMode ? "$$" : "$";
        return `<code class="math-error">${escapeHTML(delimiter + source + delimiter)}</code>`;
      }
    }

    function inlineRule(state, silent) {
      if (state.src[state.pos] !== "$" || state.src[state.pos + 1] === "$") {
        return false;
      }
      let end = state.pos + 1;
      while (end < state.posMax) {
        if (state.src[end] === "\\") {
          end += 2;
          continue;
        }
        if (state.src[end] === "$") {
          break;
        }
        end += 1;
      }
      if (end >= state.posMax || end === state.pos + 1) {
        return false;
      }
      const source = state.src.slice(state.pos + 1, end);
      if (!source.trim() || /\s$/.test(source)) {
        return false;
      }
      if (!silent) {
        const token = state.push("math_inline", "math", 0);
        token.content = source;
      }
      state.pos = end + 1;
      return true;
    }

    function blockRule(state, startLine, endLine, silent) {
      const start = state.bMarks[startLine] + state.tShift[startLine];
      const maximum = state.eMarks[startLine];
      const firstLine = state.src.slice(start, maximum);
      if (!firstLine.startsWith("$$")) {
        return false;
      }
      if (silent) {
        return true;
      }

      let source = firstLine.slice(2);
      let nextLine = startLine;
      const sameLineEnd = source.indexOf("$$");
      if (sameLineEnd >= 0) {
        source = source.slice(0, sameLineEnd);
      } else {
        const lines = [source];
        let found = false;
        for (nextLine = startLine + 1; nextLine < endLine; nextLine += 1) {
          const lineStart = state.bMarks[nextLine] + state.tShift[nextLine];
          const lineEnd = state.eMarks[nextLine];
          const line = state.src.slice(lineStart, lineEnd);
          const closing = line.indexOf("$$");
          if (closing >= 0) {
            lines.push(line.slice(0, closing));
            found = true;
            break;
          }
          lines.push(line);
        }
        if (!found) {
          return false;
        }
        source = lines.join("\n");
      }

      const token = state.push("math_block", "math", 0);
      token.block = true;
      token.content = source.trim();
      token.map = [startLine, nextLine + 1];
      state.line = nextLine + 1;
      return true;
    }

    md.inline.ruler.before("escape", "math_inline", inlineRule);
    md.block.ruler.before("fence", "math_block", blockRule, {
      alt: ["paragraph", "reference", "blockquote", "list"]
    });
    md.renderer.rules.math_inline = (tokens, index) =>
      `<span class="math-inline">${renderMath(tokens[index].content, false)}</span>`;
    md.renderer.rules.math_block = (tokens, index) =>
      `<div class="math-display">${renderMath(tokens[index].content, true)}</div>`;
  }

  const md = vendors.markdownit({
    html: false,
    linkify: true,
    breaks: true,
    typographer: false,
    highlight(source, language) {
      if (language && vendors.hljs.getLanguage(language)) {
        try {
          return vendors.hljs.highlight(source, {
            language,
            ignoreIllegals: true
          }).value;
        } catch {
          return escapeHTML(source);
        }
      }
      return escapeHTML(source);
    }
  }).use(mathPlugin);

  const defaultLinkOpen = md.renderer.rules.link_open
    || ((tokens, index, options, _environment, self) =>
      self.renderToken(tokens, index, options));
  md.renderer.rules.link_open = (tokens, index, options, environment, self) => {
    tokens[index].attrSet("rel", "noreferrer noopener");
    tokens[index].attrSet("target", "_blank");
    return defaultLinkOpen(tokens, index, options, environment, self);
  };

  md.renderer.rules.image = (tokens, index) => {
    const label = tokens[index].content || tokens[index].attrGet("alt") || "Image";
    return `<span class="image-placeholder">[${escapeHTML(label)}]</span>`;
  };

  const defaultTableOpen = md.renderer.rules.table_open
    || ((tokens, index, options, _environment, self) =>
      self.renderToken(tokens, index, options));
  md.renderer.rules.table_open = (tokens, index, options, environment, self) =>
    `<div class="table-scroll">${defaultTableOpen(tokens, index, options, environment, self)}`;
  md.renderer.rules.table_close = () => "</table></div>";

  md.renderer.rules.fence = (tokens, index, options, environment) => {
    const token = tokens[index];
    const language = token.info.trim().split(/\s+/)[0] || "";
    const highlighted = options.highlight(token.content, language);
    const codeID = `code-${environment.messageID || "message"}-${index}`;
    copyTextByID.set(codeID, token.content);
    return [
      '<div class="code-block">',
      '<div class="code-header">',
      `<span>${escapeHTML(language || "code")}</span>`,
      `<button type="button" class="copy-content copy-code" data-copy-id="${codeID}">${escapeHTML(localized("copy"))}</button>`,
      "</div>",
      `<pre><code class="hljs${language ? ` language-${escapeHTML(language)}` : ""}">${highlighted}</code></pre>`,
      "</div>"
    ].join("");
  };

  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) {
      node.className = className;
    }
    if (text !== undefined) {
      node.textContent = String(text);
    }
    return node;
  }

  function validExternalURL(rawValue) {
    try {
      const value = new URL(String(rawValue));
      if ((value.protocol === "http:" || value.protocol === "https:")
          && !value.username && !value.password) {
        return value.href;
      }
    } catch {
      return null;
    }
    return null;
  }

  function renderUser(message) {
    const wrapper = element("section", "message message-user");
    wrapper.dataset.messageId = message.id;
    wrapper.append(element("div", "user-bubble", message.content || ""));
    if (Array.isArray(message.attachments) && message.attachments.length) {
      const attachments = element("div", "message-attachments");
      message.attachments.forEach((attachment) => {
        const item = element("div", "message-attachment");
        const pages = attachment.artifact?.pageCount;
        const detail = attachment.state === "failed"
          ? (attachment.issue?.message || localized("attachmentUnavailable"))
          : attachment.state === "advancedParserRequired"
          ? localized("noExtractableText")
          : attachment.kind === "text"
            ? `${attachment.artifact?.chunkCount || 0} ${localized("sections")} · ${localized("nativeText")}`
          : pages
            ? `${pages} ${localized("pages")} · ${attachment.artifact?.parserID || "local"}`
            : attachment.kind === "image"
              ? localized("image")
              : localized("pdf");
        item.append(
          element("strong", "", attachment.displayName || localized("attachment")),
          element("span", "", detail)
        );
        attachments.append(item);
      });
      wrapper.append(attachments);
    }
    const actions = element("div", "message-actions message-actions-user");
    actions.append(messageAction("edit", message.id, localized("edit")));
    wrapper.append(actions);
    return wrapper;
  }

  function messageAction(action, messageID, label) {
    const button = element("button", "message-action", label);
    button.type = "button";
    button.dataset.transcriptAction = action;
    button.dataset.messageId = messageID;
    return button;
  }

  function renderThinking(message) {
    const source = typeof message.thinking === "string"
      ? message.thinking.trim()
      : "";
    if (!source) {
      return null;
    }
    const disclosure = element("details", "thinking");
    disclosure.dataset.disclosureId = `thinking-${message.id}`;
    disclosure.append(element("summary", "", localized("thinking")));
    disclosure.append(element("pre", "thinking-content", message.thinking));
    return disclosure;
  }

  function renderGenerating(active) {
    const generating = element(
      "div",
      "generating",
      active ? localized("generating") : localized("noResponse")
    );
    if (active) {
      const dots = element("span", "generating-dots");
      dots.setAttribute("aria-hidden", "true");
      dots.append(document.createElement("i"), document.createElement("i"), document.createElement("i"));
      generating.append(dots);
    }
    return generating;
  }

  function enhanceCopyableQuotes(markdown, messageID) {
    Array.from(markdown.querySelectorAll("blockquote")).forEach((quote, index) => {
      if (quote.parentElement?.closest("blockquote")) {
        return;
      }
      const text = quote.innerText.trim();
      if (!text) {
        return;
      }
      const copyID = `quote-${messageID}-${index}`;
      copyTextByID.set(copyID, text);
      const card = element("section", "quote-card");
      const header = element("div", "quote-card-header");
      const copyButton = element("button", "copy-content copy-quote", localized("copy"));
      copyButton.type = "button";
      copyButton.dataset.copyId = copyID;
      header.append(element("span", "", localized("copyableText")), copyButton);
      quote.replaceWith(card);
      card.append(header, quote);
    });
  }

  function renderAssistant(message, active) {
    const wrapper = element("section", "message message-assistant");
    wrapper.dataset.messageId = message.id;
    const body = element("div", "assistant-body");
    const thinking = renderThinking(message);
    if (thinking) {
      body.append(thinking);
    }

    if (message.responseIssue?.message) {
      body.append(
        element("div", "response-issue", message.responseIssue.message)
      );
    }

    if (message.content) {
      const markdown = element("div", "markdown");
      const rendered = md.render(message.content, { messageID: message.id });
      markdown.innerHTML = vendors.DOMPurify.sanitize(rendered, {
        USE_PROFILES: { html: true, mathMl: true, svg: true },
        FORBID_TAGS: ["script", "style", "iframe", "object", "embed", "form", "img"],
        FORBID_ATTR: ["src", "srcset"]
      });
      enhanceCopyableQuotes(markdown, message.id);
      body.append(markdown);
      const copyID = `message-${message.id}`;
      copyTextByID.set(copyID, message.content);
      const actions = element("div", "message-actions");
      const copyResponse = element(
        "button",
        "copy-content copy-response",
        localized("copyResponse")
      );
      copyResponse.type = "button";
      copyResponse.dataset.copyId = copyID;
      actions.append(copyResponse);
      const state = message.responseState || "complete";
      const hasToolCalls = Array.isArray(message.toolCalls)
        && message.toolCalls.length > 0;
      if (!active && (state === "failed" || state === "stopped")) {
        actions.append(messageAction("retry", message.id, localized("retry")));
      } else if (!active && state === "complete" && !hasToolCalls) {
        actions.append(messageAction("regenerate", message.id, localized("regenerate")));
      }
      body.append(actions);
    } else {
      body.append(renderGenerating(active));
      if (!active && (message.responseState === "failed"
          || message.responseState === "stopped")) {
        const actions = element("div", "message-actions");
        actions.append(messageAction("retry", message.id, localized("retry")));
        body.append(actions);
      }
    }
    wrapper.append(body);
    return wrapper;
  }

  function renderMessage(message, active) {
    if (message.role === "user") {
      return renderUser(message);
    }
    if (message.role === "assistant") {
      return renderAssistant(message, active);
    }
    if (message.role === "tool") {
      return renderTool(message);
    }
    return null;
  }

  function renderSignature(message, active) {
    return JSON.stringify({
      role: message.role,
      content: message.content || "",
      thinking: message.thinking || "",
      tool: message.tool || null,
      responseState: message.responseState || null,
      responseIssue: message.responseIssue || null,
      toolCalls: message.toolCalls || null,
      attachments: message.attachments || null,
      active
    });
  }

  function renderTool(message) {
    if (!message.tool) {
      return null;
    }
    const tool = message.tool;
    const status = ["running", "success", "failure"].includes(tool.status)
      ? tool.status
      : "failure";
    const wrapper = element("section", "message message-tool");
    wrapper.dataset.messageId = message.id;
    const card = element("div", "tool-card");
    card.dataset.status = status;

    const displayNames = {
      web_search: localized("webSearch"),
      fetch_url: localized("readWebpage"),
      browser_snapshot: localized("readWebpage"),
      browser_extract: localized("readWebpage"),
      local_search: localized("nearbySearch"),
      local_context: localized("localContext"),
      code_interpreter: localized("localCalculation")
    };
    const statusLabels = {
      running: localized("running"),
      success: localized("complete"),
      failure: localized("failed")
    };

    const header = element("div", "tool-header");
    header.append(
      element("span", "tool-status-dot"),
      element("span", "tool-name", displayNames[tool.name] || tool.name || localized("tool")),
      element("span", "tool-status", statusLabels[status])
    );
    card.append(header);

    if (tool.inputSummary) {
      card.append(element("p", "tool-summary", tool.inputSummary));
    }
    if (tool.reason) {
      card.append(element("p", "tool-reason", tool.reason));
    }
    if (tool.detail && status === "failure") {
      card.append(element("pre", "tool-detail-content tool-error", tool.detail));
    } else if (tool.detail) {
      const disclosureID = `tool-${message.id}`;
      const panelID = `${disclosureID}-panel`;
      const disclosure = element("div", "tool-detail");
      const toggle = element("button", "tool-detail-toggle", localized("details"));
      toggle.type = "button";
      toggle.dataset.disclosureId = disclosureID;
      toggle.setAttribute("aria-expanded", "false");
      toggle.setAttribute("aria-controls", panelID);
      const panel = element("pre", "tool-detail-content", tool.detail);
      panel.id = panelID;
      panel.hidden = true;
      disclosure.append(toggle, panel);
      card.append(disclosure);
    }

    if (Array.isArray(tool.sources) && tool.sources.length) {
      const sources = element("div", "source-list");
      tool.sources.slice(0, 8).forEach((source) => {
        const url = validExternalURL(source.url);
        if (!url) {
          return;
        }
        const chip = element(
          "button",
          "source-chip",
          source.title || source.url
        );
        chip.type = "button";
        chip.dataset.externalUrl = url;
        chip.title = source.url;
        sources.append(chip);
      });
      if (sources.childElementCount) {
        card.append(sources);
      }
    }
    wrapper.append(card);
    return wrapper;
  }

  function captureOpenDisclosures() {
    return new Set([
      ...Array.from(document.querySelectorAll("details[open][data-disclosure-id]"))
        .map((node) => node.dataset.disclosureId),
      ...Array.from(document.querySelectorAll(
        '.tool-detail-toggle[aria-expanded="true"][data-disclosure-id]'
      )).map((node) => node.dataset.disclosureId)
    ]);
  }

  function restoreOpenDisclosures(identifiers) {
    document.querySelectorAll("details[data-disclosure-id]").forEach((node) => {
      node.open = identifiers.has(node.dataset.disclosureId);
    });
    document.querySelectorAll(".tool-detail-toggle[data-disclosure-id]").forEach((button) => {
      const expanded = identifiers.has(button.dataset.disclosureId);
      button.setAttribute("aria-expanded", expanded ? "true" : "false");
      const panel = document.getElementById(button.getAttribute("aria-controls"));
      if (panel) {
        panel.hidden = !expanded;
      }
    });
  }

  function scheduleUserAnchor(messageID, requestID) {
    if (!messageID
        || requestID === handledScrollRequestID
        || requestID === pendingScrollRequestID) {
      return;
    }
    if (pendingScrollTimer !== null) {
      clearTimeout(pendingScrollTimer);
    }
    pendingScrollRequestID = requestID;
    pendingScrollTimer = setTimeout(() => {
      pendingScrollTimer = null;
      pendingScrollRequestID = null;
      const node = Array.from(transcript.children).find(
        (candidate) => candidate.dataset.messageId === messageID
      );
      if (!node) {
        return;
      }
      const scroller = document.scrollingElement || document.documentElement;
      const targetTop = Math.max(
        0,
        node.getBoundingClientRect().top + scroller.scrollTop - 18
      );
      scroller.scrollTop = targetTop;
      handledScrollRequestID = requestID;
      transcript.dataset.handledScrollAnchorId = messageID;
      transcript.dataset.handledScrollRequestId = requestID;
    }, 0);
  }

  window.renderConversation = function renderConversation(payload) {
    labels = {
      ...defaultLabels,
      ...(payload?.localization?.labels || {})
    };
    document.documentElement.lang = payload?.localization?.languageCode || "en";
    const messages = payload && Array.isArray(payload.messages)
      ? payload.messages.filter(
          (message) => !(message.role === "assistant"
            && Array.isArray(message.toolCalls)
            && message.toolCalls.length > 0)
        )
      : [];
    const active = Boolean(payload && payload.isActive);
    const requestedScrollAnchorID = payload?.scrollAnchorMessageID || null;
    const requestedScrollRequestID = payload?.scrollRequestID
      || requestedScrollAnchorID;
    transcript.dataset.requestedScrollAnchorId = requestedScrollAnchorID || "";
    transcript.dataset.requestedScrollRequestId = requestedScrollRequestID || "";
    const scrollingElement = document.scrollingElement || document.documentElement;
    const distanceFromBottom = scrollingElement.scrollHeight
      - scrollingElement.scrollTop
      - scrollingElement.clientHeight;
    const newestNewUserID = [...messages]
      .reverse()
      .find(
        (message) => message.role === "user"
          && !renderedMessageIDs.has(message.id)
      )?.id;
    const shouldFollowOnCompletion = wasActive
      && !active
      && distanceFromBottom < 160;
    const openDisclosures = captureOpenDisclosures();
    if (!messages.length) {
      if (!transcript.querySelector(".empty-state")) {
        const empty = element("div", "empty-state");
        empty.append(
          element("strong", "", "PrivateAI"),
          element("span", "", localized("privateConversation"))
        );
        transcript.replaceChildren(empty);
      }
    } else {
      transcript.querySelector(".empty-state")?.remove();
      const lastAssistantID = [...messages]
        .reverse()
        .find((message) => message.role === "assistant")?.id;
      const desiredIDs = new Set(messages.map((message) => message.id));
      const existing = new Map(
        Array.from(transcript.children)
          .filter((node) => node.dataset.messageId)
          .map((node) => [node.dataset.messageId, node])
      );

      messages.forEach((message, position) => {
        const isActive = active && message.id === lastAssistantID;
        const signature = renderSignature(message, isActive);
        let node = existing.get(message.id);
        if (!node || node.dataset.renderSignature !== signature) {
          const replacement = renderMessage(message, isActive);
          if (!replacement) {
            return;
          }
          replacement.dataset.renderSignature = signature;
          if (node) {
            node.replaceWith(replacement);
          }
          node = replacement;
        }
        const nodeAtPosition = transcript.children[position];
        if (nodeAtPosition !== node) {
          transcript.insertBefore(node, nodeAtPosition || null);
        }
      });

      existing.forEach((node, identifier) => {
        if (!desiredIDs.has(identifier)) {
          node.remove();
        }
      });

      let tail = transcript.querySelector(".conversation-tail");
      if (!tail) {
        tail = element("div", "conversation-tail");
      }
      tail.dataset.active = active ? "true" : "false";
      transcript.append(tail);
    }
    restoreOpenDisclosures(openDisclosures);
    renderedMessageIDs = new Set(messages.map((message) => message.id));
    const liveCopyIDs = new Set(
      Array.from(document.querySelectorAll(".copy-content[data-copy-id]"))
        .map((button) => button.dataset.copyId)
    );
    copyTextByID.forEach((_value, identifier) => {
      if (!liveCopyIDs.has(identifier)) {
        copyTextByID.delete(identifier);
      }
    });
    const scrollAnchorID = requestedScrollAnchorID || newestNewUserID;
    const scrollRequestID = requestedScrollRequestID || newestNewUserID;
    if (scrollAnchorID && scrollRequestID !== handledScrollRequestID) {
      scheduleUserAnchor(scrollAnchorID, scrollRequestID);
    } else if (shouldFollowOnCompletion) {
      requestAnimationFrame(() => requestAnimationFrame(() => {
        const scroller = document.scrollingElement || document.documentElement;
        scroller.scrollTo({ top: scroller.scrollHeight, behavior: "auto" });
      }));
    }
    wasActive = active;
  };

  document.addEventListener("click", (event) => {
    const actionButton = event.target.closest(".message-action");
    if (actionButton) {
      const action = actionButton.dataset.transcriptAction;
      const messageID = actionButton.dataset.messageId;
      if (["edit", "retry", "regenerate"].includes(action)
          && messageID
          && window.webkit?.messageHandlers?.transcriptAction) {
        window.webkit.messageHandlers.transcriptAction.postMessage({
          action,
          messageID
        });
      }
      return;
    }

    const detailToggle = event.target.closest(".tool-detail-toggle");
    if (detailToggle) {
      const panel = document.getElementById(detailToggle.getAttribute("aria-controls"));
      if (panel) {
        const expanded = detailToggle.getAttribute("aria-expanded") === "true";
        detailToggle.setAttribute("aria-expanded", expanded ? "false" : "true");
        panel.hidden = expanded;
      }
      return;
    }

    const copyButton = event.target.closest(".copy-content");
    if (copyButton) {
      const text = copyTextByID.get(copyButton.dataset.copyId);
      if (typeof text === "string" && window.webkit?.messageHandlers?.copyText) {
        window.webkit.messageHandlers.copyText.postMessage(text);
        const originalLabel = copyButton.textContent;
        copyButton.textContent = localized("copied");
        window.setTimeout(() => {
          if (copyButton.isConnected) {
            copyButton.textContent = originalLabel;
          }
        }, 1200);
      }
      return;
    }

    const sourceButton = event.target.closest("[data-external-url]");
    const anchor = event.target.closest("a[href]");
    const rawURL = sourceButton?.dataset.externalUrl || anchor?.href;
    if (rawURL) {
      event.preventDefault();
      const url = validExternalURL(rawURL);
      if (url && window.webkit?.messageHandlers?.openExternal) {
        window.webkit.messageHandlers.openExternal.postMessage(url);
      }
    }
  });
})();
