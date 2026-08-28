# Contributing to PrivateAI

Thank you for improving PrivateAI.

## Before opening a pull request

- Search existing issues before creating a duplicate.
- Keep changes focused and avoid unrelated formatting or generated-file churn.
- Never commit prompts, chat logs, documents, credentials, signing material, or local environment files.
- Add or update deterministic tests when behavior changes.
- Explain privacy, security, compatibility, and migration effects in the pull request.

## Local development

1. Install and start Ollama.
2. Open `PrivateAI/PrivateAI.xcodeproj`.
3. If you are not a member of the checked-in Apple development team, select your own Team and change the app and test bundle identifiers locally.
4. Build the `PrivateAI` scheme or run the shared `PrivateAI-Tests` scheme.

The checked-in Team ID and bundle identifiers identify the maintained app. They are not credentials and grant no signing access. Never submit a signing certificate, private key, provisioning profile, API key, token, password, notarization credential, or temporary keychain.

## Generated web assets

When changing `WebBuild/src/vendor.js` or dependencies, run:

```bash
cd WebBuild
npm install
npm test
npm run build
```

Commit the regenerated `PrivateAI/PrivateAI/Web/vendor.js` only when its source or dependencies changed. Preserve all bundled third-party license files.

## Reporting security issues

Do not open a public issue for a vulnerability or accidental secret exposure. Follow `SECURITY.md`.
