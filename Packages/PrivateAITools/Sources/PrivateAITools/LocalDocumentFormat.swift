import Foundation
import UniformTypeIdentifiers

public enum LocalDocumentFormat: String, CaseIterable, Sendable {
    case pdf
    case markdown
    case plainText = "plain_text"
    case json
    case csv
    case xml
    case html
    case yaml
    case sourceCode = "source_code"
    case unsupported

    public var isSupported: Bool {
        self != .unsupported
    }

    public var preferredFilenameExtension: String? {
        switch self {
        case .pdf: "pdf"
        case .markdown: "md"
        case .plainText: "txt"
        case .json: "json"
        case .csv: "csv"
        case .xml: "xml"
        case .html: "html"
        case .yaml: "yaml"
        case .sourceCode, .unsupported: nil
        }
    }

    var isText: Bool {
        self != .pdf && isSupported
    }

    public static func detect(url: URL) -> LocalDocumentFormat {
        let fileExtension = url.pathExtension.lowercased()
        if let format = extensions[fileExtension] {
            return format
        }
        if fileExtension.isEmpty {
            return .plainText
        }
        return .unsupported
    }

    public static func supports(url: URL) -> Bool {
        detect(url: url).isSupported
    }

    public static var supportedContentTypes: [UTType] {
        var identifiers = Set<String>()
        return extensions.keys.sorted().compactMap { fileExtension in
            guard let type = UTType(filenameExtension: fileExtension),
                  identifiers.insert(type.identifier).inserted
            else {
                return nil
            }
            return type
        }
    }

    public static var supportedFilenameExtensions: [String] {
        extensions.keys.sorted()
    }

    private static let extensions: [String: LocalDocumentFormat] = [
        "pdf": .pdf,
        "md": .markdown,
        "markdown": .markdown,
        "txt": .plainText,
        "text": .plainText,
        "log": .plainText,
        "json": .json,
        "jsonl": .json,
        "csv": .csv,
        "tsv": .csv,
        "xml": .xml,
        "html": .html,
        "htm": .html,
        "yaml": .yaml,
        "yml": .yaml,
        "toml": .plainText,
        "ini": .plainText,
        "swift": .sourceCode,
        "m": .sourceCode,
        "mm": .sourceCode,
        "h": .sourceCode,
        "c": .sourceCode,
        "cc": .sourceCode,
        "cpp": .sourceCode,
        "js": .sourceCode,
        "jsx": .sourceCode,
        "ts": .sourceCode,
        "tsx": .sourceCode,
        "py": .sourceCode,
        "rb": .sourceCode,
        "go": .sourceCode,
        "rs": .sourceCode,
        "java": .sourceCode,
        "kt": .sourceCode,
        "kts": .sourceCode,
        "sh": .sourceCode,
        "zsh": .sourceCode,
        "sql": .sourceCode
    ]
}