# Contributing to PrivateAI

Thank you for improving PrivateAI.

## Before opening a pull request

- Search existing issues before creating a duplicate.
- Keep changes focused and avoid unrelated formatting or generated-file churn.
- Never commit prompts, chat logs, documents, credentials, signing material, or local environment files.
- Add or update deterministic tests when behavior changes.
- Explain privacy, security, compatibility, and migration effects in the pull request.

## Local development

1. Open `Private AI/Private AI.xcodeproj`.
2. If you are not a member of the checked-in Apple development team, select your own Team and change the app and test bundle identifiers locally.
3. Build the `Private AI` target or run the unit-test and UI-test targets from Xcode.

The repository is being rebuilt from a minimal application scaffold. Ollama, a web transcript build, and product-specific test fixtures are not current development prerequisites. Document new prerequisites only after the corresponding implementation is checked in.

The checked-in Team ID and bundle identifiers identify the maintained app. They are not credentials and grant no signing access. Never submit a signing certificate, private key, provisioning profile, API key, token, password, notarization credential, or temporary keychain.

## Reporting security issues

Do not open a public issue for a vulnerability or accidental secret exposure. Follow `SECURITY.md`.
