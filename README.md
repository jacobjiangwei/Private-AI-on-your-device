# PrivateAI

PrivateAI is being rebuilt as a native, on-device macOS assistant. The intended product direction is documented in [the target architecture draft](docs/product/target-architecture-draft.md).

## Status

The repository contains a development build of a native macOS chat application with Ollama model integration, persistent conversations, Markdown transcript rendering, built-in tools, and managed local document attachments. Expect breaking changes; current builds are for development only.

The attachment workflow supports searchable PDFs through PDFKit plus Markdown, plain text, structured text, HTML, and common source-code formats. Whole-document work uses resumable hierarchical summarization: each page or chunk is summarized to a private local checkpoint, then summaries are recursively reduced to fit model context. See [Document Attachments](docs/product/document-attachments.md) for the verified format matrix, limits, storage model, and unsupported cases such as scanned PDFs without OCR.

## Requirements

- macOS and an Xcode version that support the SDK and deployment target configured in the project
- Ollama with a compatible local chat model installed

The App discovers locally installed Ollama models at runtime; availability and model performance depend on the local Ollama installation and hardware.

## Build

1. Open `Private AI/Private AI.xcodeproj` in Xcode.
2. Select the `Private AI` target.
3. Build and run the macOS app.

The checked-in Team ID and bundle identifiers are public project metadata, not signing credentials. Maintainers with the matching local development certificate can build immediately. Other contributors should select their own Team and use a unique bundle identifier under Signing & Capabilities. The repository intentionally contains no signing certificate, private key, provisioning profile, API token, password, or notarization credential.

## Tests

The repository includes Swift package tests, macOS App unit tests, direct framework integrations, real PDF fixtures, and opt-in live Ollama scenarios. Live model and network tests require their corresponding local or external services and must be reported separately from deterministic contract tests.

## Releases

Signed and notarized macOS DMGs are published through [GitHub Releases](https://github.com/jacobjiangwei/Private-AI-on-your-device/releases). Each push to `main` runs the release workflow, verifies Developer ID signatures and Gatekeeper assessment, notarizes and staples the DMG, and publishes a SHA-256 checksum. See [Direct Release](docs/direct-release.md) for the verified release flow and maintainer configuration.

## Privacy

Model inference runs through the user's local Ollama service. Selected documents are copied into private managed storage under `~/.privateAI/artifacts`; document bytes and extracted text are not stored in message rows or runtime logs. Built-in network tools can access public network resources when the model invokes them. See [the privacy policy](docs/privacy-policy.md) and [Document Attachments](docs/product/document-attachments.md) for the current development-state data flow.

## Security

Do not post secrets, private documents, or chat content in public issues. See [SECURITY.md](SECURITY.md) for private vulnerability reporting and supported-version expectations.

## Contributing

Issues and pull requests are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md).

## License

PrivateAI source code is available under the [Apache License 2.0](LICENSE). Third-party notices must be updated whenever dependencies or redistributable components are introduced.