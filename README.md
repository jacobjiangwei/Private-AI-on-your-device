# PrivateAI

PrivateAI is being rebuilt as a native, on-device macOS assistant. The intended product direction is documented in [the target architecture draft](docs/product/target-architecture-draft.md).

## Status

The repository currently contains a minimal Xcode application scaffold, not a usable AI assistant. Chat, model integration, Markdown rendering, persistence, document handling, tools, and release packaging have not yet been reimplemented. Expect breaking changes; current builds are for development only.

## Requirements

- macOS and an Xcode version that support the SDK and deployment target configured in the project

Ollama and a local model are not required by the current scaffold. Runtime requirements will be documented when model integration is implemented.

## Build

1. Open `Private AI/Private AI.xcodeproj` in Xcode.
2. Select the `Private AI` target.
3. Build and run the macOS app.

The checked-in Team ID and bundle identifiers are public project metadata, not signing credentials. Maintainers with the matching local development certificate can build immediately. Other contributors should select their own Team and use a unique bundle identifier under Signing & Capabilities. The repository intentionally contains no signing certificate, private key, provisioning profile, API token, password, or notarization credential.

## Tests

The Xcode project contains template unit-test and UI-test targets, but no meaningful product test suite yet. Test commands and fixtures will be documented as functionality is rebuilt.

## Releases

There is currently no supported release build. A retained GitHub Actions workflow describes the previous direct-distribution process, but it depends on deleted build scripts and must not be treated as operational. See [the paused release plan](docs/direct-release.md).

## Privacy

The current scaffold does not perform AI inference, import documents, or implement product network tools. See [the privacy policy](docs/privacy-policy.md) for the current development-state data flow.

## Security

Do not post secrets, private documents, or chat content in public issues. See [SECURITY.md](SECURITY.md) for private vulnerability reporting and supported-version expectations.

## Contributing

Issues and pull requests are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md).

## License

PrivateAI source code is available under the [Apache License 2.0](LICENSE). Third-party notices must be updated whenever dependencies or redistributable components are introduced.