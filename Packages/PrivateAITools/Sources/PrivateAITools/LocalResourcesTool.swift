import Foundation
import LLMCore
import PDFKit
import UniformTypeIdentifiers

public enum LocalResourcesToolError: Error, Equatable, LocalizedError, Sendable {
    case outsideAuthorizedRoots(String)
    case resourceNotFound(String)
    case unsupportedFileType(String)
    case fileTooLarge(Int)
    case unreadablePDF
    case lockedPDF
    case invalidPageRange

    public var errorDescription: String? {
        switch self {
        case .outsideAuthorizedRoots(let path):
            "The path '\(path)' is outside the locations available to PrivateAI."
        case .resourceNotFound(let path):
            "The local resource '\(path)' does not exist."
        case .unsupportedFileType(let type):
            "The local resource type '\(type)' is not supported."
        case .fileTooLarge(let limit):
            "The local resource exceeded the \(limit)-byte limit."
        case .unreadablePDF:
            "PDFKit could not open the PDF document."
        case .lockedPDF:
            "The PDF document is locked and cannot be read."
        case .invalidPageRange:
            "The requested PDF page range is invalid."
        }
    }
}

public actor LocalResourcesTool: LLMTool {
    public nonisolated let definition = ToolDefinition(
        function: ToolFunctionDefinition(
            name: "local_resources",
            description: "Work with local directories and documents on this Mac. List directory contents, read documents, or search within documents. Supported documents include Markdown, plain text, HTML, JSON, CSV, XML, YAML, source code, and PDF.",
            parameters: objectSchema(
                properties: [
                    "action": stringSchema(
                        description: "Operation: list returns directory entries; read returns document content; search finds text within one document.",
                        values: ["list", "read", "search"]
                    ),
                    "path": stringSchema(description: "Absolute path to a local directory or document. Tilde (~) is expanded to the user's home directory."),
                    "query": stringSchema(description: "Text to find when action is search."),
                    "page_start": integerSchema(description: "Optional first PDF page to read, one-based and inclusive.", range: 1...100_000),
                    "page_end": integerSchema(description: "Optional last PDF page to read, one-based and inclusive.", range: 1...100_000),
                    "limit": integerSchema(description: "Optional maximum directory entries or search matches.", range: 1...500)
                ],
                required: ["action", "path"]
            )
        )
    )

    private let authorizedRoots: [URL]
    private let maximumFileBytes: Int
    private let maximumTextCharacters: Int
    private let fileManager: FileManager

    public init(
        authorizedRoots: [URL],
        maximumFileBytes: Int = 20 * 1_024 * 1_024,
        maximumTextCharacters: Int = 200_000,
        fileManager: FileManager = .default
    ) {
        self.authorizedRoots = authorizedRoots.map {
            $0.standardizedFileURL.resolvingSymlinksInPath()
        }
        self.maximumFileBytes = maximumFileBytes
        self.maximumTextCharacters = maximumTextCharacters
        self.fileManager = fileManager
    }

    public nonisolated func isConcurrencySafe(arguments: [String: JSONValue]) -> Bool {
        switch arguments["action"]?.stringValue {
        case "list", "read", "search": true
        default: false
        }
    }

    public func execute(arguments: [String: JSONValue]) async throws -> String {
        let values = CapabilityArguments(values: arguments)
        let action = try values.requiredString("action", maximumBytes: 32)
        let rawPath = try values.requiredString("path", maximumBytes: 4_096)
        let resource = try resolve(rawPath)
        let accessedSecurityScope = resource.root.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope {
                resource.root.stopAccessingSecurityScopedResource()
            }
        }
        let result: JSONValue

        switch action {
        case "list":
            try values.requireOnly(["action", "path", "limit"])
            result = try listDirectory(
                resource.url,
                limit: try values.optionalInteger("limit", range: 1...500) ?? 100
            )
        case "read":
            try values.requireOnly(["action", "path", "page_start", "page_end"])
            result = try readDocument(
                resource.url,
                pageStart: try values.optionalInteger("page_start", range: 1...100_000),
                pageEnd: try values.optionalInteger("page_end", range: 1...100_000)
            )
        case "search":
            try values.requireOnly(["action", "path", "query", "limit"])
            result = try searchDocument(
                resource.url,
                query: try values.requiredString("query", maximumBytes: 2_048),
                limit: try values.optionalInteger("limit", range: 1...500) ?? 50
            )
        default:
            throw CapabilityToolError.unsupportedAction(action)
        }

        return try encodeToolResult(result)
    }

    private func resolve(_ path: String) throws -> AuthorizedResource {
        let expanded = (path as NSString).expandingTildeInPath
        let candidate: URL
        if expanded.hasPrefix("/") {
            candidate = URL(fileURLWithPath: expanded)
        } else if let base = authorizedRoots.first {
            candidate = base.appending(path: expanded)
        } else {
            candidate = URL(fileURLWithPath: fileManager.homeDirectoryForCurrentUser.path)
                .appending(path: expanded)
        }
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        // Empty authorizedRoots means unrestricted: the tool reads anything the process can access.
        let root: URL
        if authorizedRoots.isEmpty {
            root = resolved
        } else if let matched = authorizedRoots.first(where: { contains(resolved, root: $0) }) {
            root = matched
        } else {
            throw LocalResourcesToolError.outsideAuthorizedRoots(path)
        }
        guard fileManager.fileExists(atPath: resolved.path) else {
            throw LocalResourcesToolError.resourceNotFound(path)
        }
        return AuthorizedResource(url: resolved, root: root)
    }

    private func contains(_ resource: URL, root: URL) -> Bool {
        let resourceComponents = resource.pathComponents
        let rootComponents = root.pathComponents
        return resourceComponents.count >= rootComponents.count
            && Array(resourceComponents.prefix(rootComponents.count)) == rootComponents
    }

    private func listDirectory(_ url: URL, limit: Int) throws -> JSONValue {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw CapabilityToolError.invalidArgument("path")
        }
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .contentTypeKey
        ]
        let children = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        let entries = try children
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(limit)
            .map { child -> JSONValue in
                let values = try child.resourceValues(forKeys: keys)
                return .object([
                    "name": .string(child.lastPathComponent),
                    "path": .string(child.path),
                    "is_directory": .bool(values.isDirectory ?? false),
                    "size_bytes": values.fileSize.map { .number(Double($0)) } ?? .null,
                    "content_type": values.contentType.map { .string($0.identifier) } ?? .null,
                    "modified_at": values.contentModificationDate.map { .string($0.ISO8601Format()) } ?? .null
                ])
            }
        return .object([
            "path": .string(url.path),
            "entries": .array(Array(entries)),
            "truncated": .bool(children.count > limit)
        ])
    }

    private func readDocument(
        _ url: URL,
        pageStart: Int?,
        pageEnd: Int?
    ) throws -> JSONValue {
        let format = documentFormat(for: url)
        if format == .pdf {
            return try readPDF(url, pageStart: pageStart, pageEnd: pageEnd)
        }
        guard pageStart == nil, pageEnd == nil else {
            throw LocalResourcesToolError.invalidPageRange
        }
        return try readText(url, format: format)
    }

    private func readText(_ url: URL, format: DocumentFormat? = nil) throws -> JSONValue {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        let fileSize = values.fileSize ?? 0
        guard fileSize <= maximumFileBytes else {
            throw LocalResourcesToolError.fileTooLarge(maximumFileBytes)
        }
        let resolvedFormat = format ?? documentFormat(for: url)
        guard resolvedFormat.isText else {
            throw LocalResourcesToolError.unsupportedFileType(
                values.contentType?.identifier ?? url.pathExtension.lowercased()
            )
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= maximumFileBytes else {
            throw LocalResourcesToolError.fileTooLarge(maximumFileBytes)
        }
        let text = String(decoding: data, as: UTF8.self)
        let truncated = text.count > maximumTextCharacters
        return .object([
            "path": .string(url.path),
            "kind": .string("text"),
            "format": .string(resolvedFormat.rawValue),
            "encoding": .string("utf-8"),
            "text": .string(String(text.prefix(maximumTextCharacters))),
            "truncated": .bool(truncated),
            "size_bytes": .number(Double(data.count))
        ])
    }

    private func readPDF(
        _ url: URL,
        pageStart: Int?,
        pageEnd: Int?
    ) throws -> JSONValue {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= maximumFileBytes else {
            throw LocalResourcesToolError.fileTooLarge(maximumFileBytes)
        }
        guard let document = PDFDocument(url: url) else {
            throw LocalResourcesToolError.unreadablePDF
        }
        guard !document.isLocked else {
            throw LocalResourcesToolError.lockedPDF
        }
        let pageCount = document.pageCount
        let start = pageStart ?? 1
        let end = pageEnd ?? pageCount
        guard pageCount > 0, start >= 1, end >= start, end <= pageCount else {
            throw LocalResourcesToolError.invalidPageRange
        }

        var pages: [JSONValue] = []
        var remainingCharacters = maximumTextCharacters
        var truncated = false
        for pageNumber in start...end {
            guard remainingCharacters > 0 else {
                truncated = true
                break
            }
            let text = document.page(at: pageNumber - 1)?.string ?? ""
            let pageText = String(text.prefix(remainingCharacters))
            pages.append(.object([
                "page": .number(Double(pageNumber)),
                "text": .string(pageText)
            ]))
            remainingCharacters -= pageText.count
            if pageText.count < text.count {
                truncated = true
                break
            }
        }
        return .object([
            "path": .string(url.path),
            "kind": .string("pdf"),
            "format": .string(DocumentFormat.pdf.rawValue),
            "page_count": .number(Double(pageCount)),
            "page_start": .number(Double(start)),
            "page_end": .number(Double(end)),
            "pages": .array(pages),
            "truncated": .bool(truncated)
        ])
    }

    private func searchDocument(_ url: URL, query: String, limit: Int) throws -> JSONValue {
        let normalizedQuery = query.localizedLowercase
        let matches: [JSONValue]
        if documentFormat(for: url) == .pdf {
            guard let document = PDFDocument(url: url), !document.isLocked else {
                throw LocalResourcesToolError.unreadablePDF
            }
            matches = document.pageCount == 0 ? [] : (0..<document.pageCount).compactMap { index in
                guard let text = document.page(at: index)?.string,
                      let context = matchContext(in: text, query: normalizedQuery)
                else {
                    return nil
                }
                return .object([
                    "page": .number(Double(index + 1)),
                    "context": .string(context)
                ])
            }
        } else {
            let object = try readText(url).objectValue ?? [:]
            let text = object["text"]?.stringValue ?? ""
            matches = matchContext(in: text, query: normalizedQuery).map {
                [.object(["context": .string($0)])]
            } ?? []
        }
        return .object([
            "path": .string(url.path),
            "query": .string(query),
            "matches": .array(Array(matches.prefix(limit))),
            "truncated": .bool(matches.count > limit)
        ])
    }

    private func matchContext(in text: String, query: String) -> String? {
        let normalizedText = text.localizedLowercase
        guard let range = normalizedText.range(of: query) else {
            return nil
        }
        let lower = normalizedText.index(range.lowerBound, offsetBy: -120, limitedBy: normalizedText.startIndex)
            ?? normalizedText.startIndex
        let upper = normalizedText.index(range.upperBound, offsetBy: 240, limitedBy: normalizedText.endIndex)
            ?? normalizedText.endIndex
        return String(text[lower..<upper]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func documentFormat(for url: URL) -> DocumentFormat {
        let fileExtension = url.pathExtension.lowercased()
        if let format = DocumentFormat.extensions[fileExtension] {
            return format
        }
        if let type = UTType(filenameExtension: fileExtension) {
            if type.conforms(to: .pdf) { return .pdf }
            if type.conforms(to: .html) { return .html }
            if type.conforms(to: .json) { return .json }
            if type.conforms(to: .plainText) || type.conforms(to: .sourceCode) {
                return .plainText
            }
        }
        if fileExtension.isEmpty {
            return .plainText
        }
        return .unsupported
    }
}

private struct AuthorizedResource {
    let url: URL
    let root: URL
}

private enum DocumentFormat: String {
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

    var isText: Bool {
        self != .pdf && self != .unsupported
    }

    static let extensions: [String: DocumentFormat] = [
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