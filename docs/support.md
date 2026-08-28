# PrivateAI Help

## Requirements

PrivateAI currently requires macOS 14 or later, Ollama for macOS, and at least one model installed in Ollama. Model downloads require additional disk space. Performance depends on the Mac, model, context size, and quantization.

## First launch

1. Install and open Ollama from its official macOS download page.
2. Install any compatible Ollama model. PrivateAI shows a recommended Qwen command that you can copy.
3. Return to PrivateAI and choose Recheck.
4. Select an installed model from the model status control.

PrivateAI never installs software or runs a model-download command without the user's action.

## Documents

Add a file with the paperclip button, drag and drop, or paste a file object from Finder. A typed filesystem path is not permission to read a file. Imported documents enter the local Document Library and can be reused in later chats.

Text-based PDFs, common text and office documents, source files, and static images are supported. Scanned PDFs without extractable text are not supported in this version.

## Delete local data

- Delete a chat from the sidebar.
- Delete a memory from Memories.
- Delete a document from the Document Library to remove its sandbox copy, extracted text, and cached local-model profiles.
- Remove PrivateAI's app container to remove all retained PrivateAI data.

Deleting a chat does not delete documents in the Document Library.

## Network activity

Core model inference is sent only to Ollama on the same Mac. When a request needs current information, PrivateAI may use DuckDuckGo search, fetch a requested website, inspect public network context, or use Apple Maps for an authorized nearby search. Tool activity and sources are shown in the conversation.

## Troubleshooting

- If PrivateAI cannot connect, make sure the Ollama app is open, then choose Recheck.
- If no model appears, install a model in Ollama and choose Recheck.
- If local data cannot be opened, use Retry. PrivateAI does not reset the data or switch to a cloud model.
- Logs can be opened from the toolbar and remain on this Mac.

## Contact

Open a GitHub issue with the PrivateAI version, macOS version, Ollama version, selected model, and the exact error message. Do not post sensitive documents, chat content, API keys, or credentials. Report security vulnerabilities privately using the process in `SECURITY.md`.
