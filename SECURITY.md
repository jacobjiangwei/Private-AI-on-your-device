# Security Policy

## Supported versions

PrivateAI is currently being rebuilt and has no supported release version. Security fixes apply to the default branch until a supported release policy is published.

## Reporting a vulnerability

Use GitHub Private Vulnerability Reporting on the repository's Security tab. Do not include vulnerabilities, private documents, chat content, API keys, tokens, passwords, signing certificates, private keys, or notarization credentials in a public issue.

Include:

- the affected version or commit;
- macOS and Xcode versions, plus versions of any relevant external service;
- clear reproduction steps;
- the expected and actual security boundary;
- impact and any known workaround.

You should receive an acknowledgement within seven days. Please allow time to validate, fix, and release before public disclosure.

## Scope

High-priority reports include sandbox escapes, unauthorized local-file access, credential disclosure, cross-session data exposure, unsafe URL access, code execution, signature/update compromise, and privacy behavior that contradicts the documented data flow.
