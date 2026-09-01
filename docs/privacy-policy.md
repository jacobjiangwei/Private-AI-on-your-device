# PrivateAI Privacy Policy

Effective date: 2026-08-29

PrivateAI is currently a development scaffold for a macOS app being rebuilt from the beginning. It is not a supported product release. This policy describes the code currently checked into this repository; planned behavior belongs in product and architecture documents, not in this current-data-flow statement.

## Core AI processing

The current scaffold does not implement chat, connect to Ollama or another model provider, process prompts, or send AI content to a local or cloud model.

## Data stored on the Mac

The current Xcode scaffold contains only template local persistence code. It does not store chats, memories, imported documents, extracted text, model profiles, or product diagnostic logs. Data created by a local development build remains in that build's app container unless it is removed through development tooling or by deleting the container.

## Network features

The current scaffold does not implement web search, URL retrieval, public-IP lookup, nearby search, analytics, advertising, or other product network features.

## File access

The current scaffold does not implement file selection, drag and drop, paste-based import, or document processing.

## Security and retention

Current development builds use the entitlements and sandbox configuration in the Xcode project. There are no product-level chat, memory, or document deletion controls yet. Removing the development app's container removes data retained in that container.

## Changes and contact

Material changes will be reflected by a new effective date. Use the repository's public support channel for privacy questions, and GitHub's private vulnerability-reporting channel for security issues.
