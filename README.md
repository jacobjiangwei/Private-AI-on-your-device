# PrivateAI

PrivateAI is a native macOS assistant that runs user-selected models through Ollama on the same Mac. It keeps conversations, imported documents, memories, and diagnostics in the app sandbox while making optional network tools visible in the conversation.

## Status

PrivateAI is early open-source software. Expect breaking changes and verify behavior before using it with sensitive or irreplaceable data.

## Requirements

- macOS 14 or later
- Xcode 16 or later for source builds
- [Ollama for macOS](https://ollama.com/download)
- At least one Ollama model

## Build

1. Install and start Ollama.
2. Open `PrivateAI/PrivateAI.xcodeproj` in Xcode.
3. Build and run the `PrivateAI` scheme.

The checked-in Team ID and bundle identifiers are public project metadata, not signing credentials. Maintainers with the matching local development certificate can build immediately. Other contributors should select their own Team and use a unique bundle identifier under Signing & Capabilities. The repository intentionally contains no signing certificate, private key, provisioning profile, API token, password, or notarization credential.

## Web Transcript Assets

The generated transcript bundle is committed so Xcode builds work without Node.js. To rebuild it:

```bash
cd WebBuild
npm install
npm run build
```

Third-party license texts for DOMPurify, highlight.js, KaTeX, and markdown-it ship with the app under `PrivateAI/PrivateAI/Web`.

## Tests

Use the shared `PrivateAI-Tests` scheme in Xcode. Live Ollama evaluations and performance benchmarks are opt-in; deterministic protocol and application tests do not require a production account or cloud model.

## Releases

Every push to `main` runs the signed GitHub Actions build, assigns the GitHub workflow run number as the app build number, and publishes a public GitHub Release such as `v1.0-build.42`. The workflow imports a Developer ID certificate from the protected `production` environment, archives the app, signs and notarizes a DMG, staples the Apple ticket, validates it with Gatekeeper, and publishes the DMG plus its SHA-256 checksum. See [the release setup guide](docs/direct-release.md).

## Privacy

Core inference is sent to the Ollama service on the same Mac. Optional web search, URL retrieval, public-network context, and nearby-search tools can contact external services when a request requires them. See [the privacy policy](docs/privacy-policy.md) for the current data-flow description.

## Security

Do not post secrets, private documents, or chat content in public issues. See [SECURITY.md](SECURITY.md) for private vulnerability reporting and supported-version expectations.

## Contributing

Issues and pull requests are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md).

## License

PrivateAI source code is available under the [Apache License 2.0](LICENSE). Bundled third-party components retain their own license notices.