import Foundation

enum AttachmentModelContentBuilder {
    static func content(for message: MessageRecord) -> String {
        let documents = message.attachments
            .sorted { $0.sortOrder < $1.sortOrder }
            .compactMap { reference -> Document? in
                guard let blob = reference.blob else { return nil }
                return Document(
                    name: reference.displayName,
                    path: blob.relativePath,
                    format: blob.formatRawValue,
                    sizeBytes: blob.byteCount
                )
            }
        guard !documents.isEmpty else { return message.content }
        let manifest = Manifest(
            type: "privateai.document_attachments",
            version: 1,
            documents: documents
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(manifest) else { return message.content }
        return """
        PrivateAI attached-document manifest. For a whole-document summary, review, or comprehensive analysis, call `document_analysis` once with action `summarize`, the relative `path`, and the user's analysis goal. It summarizes every extractable page or text chunk to private local checkpoints and recursively reduces them. Use `local_resources` only for exact local details or targeted search; do not walk every read cursor to summarize a whole document.

        ```json
        \(String(decoding: data, as: UTF8.self))
        ```

        User request:
        \(message.content)
        """
    }

    private struct Manifest: Encodable {
        let type: String
        let version: Int
        let documents: [Document]
    }

    private struct Document: Encodable {
        let name: String
        let path: String
        let format: String
        let sizeBytes: Int64

        enum CodingKeys: String, CodingKey {
            case name
            case path
            case format
            case sizeBytes = "size_bytes"
        }
    }
}