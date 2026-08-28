# PrivateAI Privacy Policy

Effective date: 2026-08-28

PrivateAI is a macOS app for using local AI models through Ollama. This policy describes what the app processes, where data goes, and how users can remove it.

## Core AI processing

PrivateAI sends core chat prompts, bounded document context, and normalized images only to the Ollama service running on the same Mac. PrivateAI does not provide a cloud-model fallback, require an account, display advertising, or include product analytics.

## Data stored on the Mac

PrivateAI stores chats, local memories, diagnostic logs, imported file copies, extracted text, and local-model document profiles inside its macOS sandbox container. This data is not sent to the developer. It remains until the user deletes it or removes the app's container.

Deleting a chat does not delete documents retained in the Document Library. Deleting a document from the Document Library permanently removes its sandbox copy, extracted text, and cached local-model profiles. Memories can be deleted from the Memories view.

## Network features

PrivateAI can use network features when a user request needs current or external information:

- Web search sends the search query to DuckDuckGo.
- URL retrieval connects to the website requested by the user or selected for the task.
- Public network context may connect to Cloudflare or ipify to determine the current public IP address.
- Nearby search uses Apple location and map services only when the user's request authorizes current-location use and macOS permission is granted.
- Setup links can open official Ollama websites in the user's browser.

PrivateAI shows tool activity and sources in the conversation. External services process requests under their own privacy policies. PrivateAI does not sell user data or use these requests for advertising or tracking.

## File access

PrivateAI reads a file only after the user selects, drops, or pastes the file through a macOS-authorized interaction. A filesystem path typed into chat is not treated as permission. Imported files are copied into the app sandbox and the external security scope is released.

## Security and retention

PrivateAI uses the macOS App Sandbox and user-selected read-only file access. Users control retention through chat, Memories, and Document Library deletion actions. Removing the app's container removes all locally retained PrivateAI data.

## Changes and contact

Material changes will be reflected by a new effective date. Use the repository's public support channel for privacy questions, and GitHub's private vulnerability-reporting channel for security issues.
