import AppKit
import Darwin
import Foundation

public enum WebToolError: LocalizedError, Sendable {
    case invalidURL(String)
    case unsafeURL(String)
    case unavailable(String)
    case responseTooLarge
    case invalidResponse
    case timedOut
    case sidecar(String)
    case httpStatus(Int, String)
    case transport(String)
    case search(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let detail): String(localized: "Invalid URL: \(detail)")
        case .unsafeURL(let detail): String(localized: "Blocked unsafe URL: \(detail)")
        case .unavailable(let detail): String(localized: "Browser tool unavailable: \(detail)")
        case .responseTooLarge: String(localized: "The response exceeded the local size limit.")
        case .invalidResponse: String(localized: "The server returned an invalid response.")
        case .timedOut: String(localized: "The request exceeded the local time limit.")
        case .sidecar(let detail): detail
        case .httpStatus(let status, let host):
            String(localized: "HTTP \(status) from \(host).")
        case .transport(let detail):
            String(localized: "Network request failed: \(detail)")
        case .search(let detail):
            String(localized: "Web search failed: \(detail)")
        }
    }
}

public enum URLSafety {
    public static func validate(_ rawValue: String, resolveDNS: Bool = true) throws -> URL {
        guard let url = URL(string: rawValue) else {
            throw WebToolError.invalidURL(rawValue)
        }
        return try validate(url, resolveDNS: resolveDNS)
    }

    public static func validate(_ url: URL, resolveDNS: Bool = true) throws -> URL {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw WebToolError.unsafeURL("only http and https are permitted")
        }
        guard url.user == nil, url.password == nil else {
            throw WebToolError.unsafeURL("URLs containing credentials are not permitted")
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            throw WebToolError.invalidURL("missing host")
        }
        if host == "localhost"
            || host.hasSuffix(".localhost")
            || host.hasSuffix(".local")
            || host == "0"
            || host == "0.0.0.0"
            || host == "::"
            || host == "::1"
        {
            throw WebToolError.unsafeURL("local hosts are not permitted")
        }
        if resolveDNS {
            try requirePublicAddresses(host: host)
        }
        return url
    }

    private static func requirePublicAddresses(host: String) throws {
        var hints = addrinfo()
        hints.ai_flags = AI_ADDRCONFIG
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            throw WebToolError.unsafeURL("the host could not be resolved")
        }
        defer { freeaddrinfo(first) }

        var cursor: UnsafeMutablePointer<addrinfo>? = first
        var foundAddress = false
        while let current = cursor {
            let info = current.pointee
            if info.ai_family == AF_INET, let addressPointer = info.ai_addr {
                foundAddress = true
                let raw = addressPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
                }
                if isPrivateIPv4(raw) {
                    throw WebToolError.unsafeURL("the host resolves to a private or local address")
                }
            } else if info.ai_family == AF_INET6, let addressPointer = info.ai_addr {
                foundAddress = true
                var address = addressPointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    $0.pointee.sin6_addr
                }
                let bytes = withUnsafeBytes(of: &address) { Array($0) }
                if isPrivateIPv6(bytes) {
                    throw WebToolError.unsafeURL("the host resolves to a private or local address")
                }
            }
            cursor = info.ai_next
        }
        if !foundAddress {
            throw WebToolError.unsafeURL("the host has no usable public address")
        }
    }

    private static func isPrivateIPv4(_ address: UInt32) -> Bool {
        let first = address >> 24
        let second = (address >> 16) & 0xff
        if first == 0 || first == 10 || first == 127 || first >= 224 { return true }
        if first == 100 && (64...127).contains(second) { return true }
        if first == 169 && second == 254 { return true }
        if first == 172 && (16...31).contains(second) { return true }
        if first == 192 && second == 168 { return true }
        if first == 198 && (second == 18 || second == 19) { return true }
        return false
    }

    private static func isPrivateIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return true }
        if bytes.allSatisfy({ $0 == 0 }) { return true }
        if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return true }
        if bytes[0] & 0xfe == 0xfc { return true }
        if bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80 { return true }
        if bytes[0] == 0xff { return true }
        if bytes[0...9].allSatisfy({ $0 == 0 })
            && bytes[10] == 0xff
            && bytes[11] == 0xff
        {
            let mapped = UInt32(bytes[12]) << 24
                | UInt32(bytes[13]) << 16
                | UInt32(bytes[14]) << 8
                | UInt32(bytes[15])
            return isPrivateIPv4(mapped)
        }
        return false
    }
}

private final class SafeRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var redirectCount = 0

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        redirectCount += 1
        let count = redirectCount
        lock.unlock()
        guard count <= 5,
              let url = request.url,
              (try? URLSafety.validate(url)) != nil
        else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

public struct SearchResult: Equatable, Sendable {
    public let title: String
    public let url: String
    public let snippet: String

    public init(title: String, url: String, snippet: String) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

public enum DuckDuckGoParser {
    public static func parse(_ html: String, limit: Int) -> [SearchResult] {
        guard limit > 0 else { return [] }
        var results: [SearchResult] = []
        for anchor in allMatches(#"(?is)<a\b([^>]*)>(.*?)</a>"#, in: html) {
            guard anchor.captures.count == 2 else { continue }
            let attributes = anchor.captures[0]
            guard let classValue = firstMatch(
                #"\bclass\s*=\s*["']([^"']+)["']"#,
                in: attributes
            )?.first,
                  classValue.contains("result__a") || classValue.contains("result-link"),
                  let rawURL = firstMatch(
                      #"\bhref\s*=\s*["']([^"']+)["']"#,
                      in: attributes
                  )?.first
            else { continue }
            let title = plainText(anchor.captures[1])
            let snippetMatch = firstMatch(
                #"(?is)<(?:a|div|td)[^>]*class\s*=\s*["'][^"']*(?:result__snippet|result-snippet)[^"']*["'][^>]*>(.*?)</(?:a|div|td)>"#,
                in: String(html[anchor.range.upperBound...].prefix(6_000))
            )
            let snippet = snippetMatch.map { plainText($0[0]) } ?? ""
            let resolvedURL = resolveDuckDuckGoRedirect(decodeEntities(rawURL))
            guard !title.isEmpty,
                  let candidate = URL(string: resolvedURL),
                  candidate.scheme == "http" || candidate.scheme == "https"
            else { continue }
            results.append(SearchResult(title: title, url: resolvedURL, snippet: snippet))
            if results.count == limit { break }
        }
        return results
    }

    private static func allMatches(
        _ pattern: String,
        in text: String
    ) -> [(range: Range<String.Index>, captures: [String])] {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: fullRange).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let captures = (1..<match.numberOfRanges).compactMap { index -> String? in
                guard let captureRange = Range(match.range(at: index), in: text) else {
                    return nil
                }
                return String(text[captureRange])
            }
            return (range, captures)
        }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        allMatches(pattern, in: text).first?.captures
    }

    private static func resolveDuckDuckGoRedirect(_ value: String) -> String {
        let normalized = value.hasPrefix("//") ? "https:\(value)" : value
        guard let components = URLComponents(string: normalized),
              components.host?.contains("duckduckgo.com") == true,
              let destination = components.queryItems?.first(where: { $0.name == "uddg" })?.value
        else { return normalized }
        return destination
    }

    private static func plainText(_ html: String) -> String {
        let withoutTags = html.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: " ",
            options: .regularExpression
        )
        return decodeEntities(withoutTags)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func decodeEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}

public actor DirectWebClient {
    private let maximumBytes: Int
    private let timeout: TimeInterval

    public init(maximumBytes: Int = 5_000_000, timeout: TimeInterval = 20) {
        self.maximumBytes = maximumBytes
        self.timeout = timeout
    }

    public func search(query: String, maximumResults: Int) async throws -> ToolResult {
        let count = min(max(maximumResults, 1), 8)
        let endpoints = [
            "https://html.duckduckgo.com/html/",
            "https://lite.duckduckgo.com/lite/"
        ]
        var failures: [String] = []
        for endpoint in endpoints {
            var components = URLComponents(string: endpoint)!
            components.queryItems = [
                URLQueryItem(name: "q", value: String(query.prefix(300)))
            ]
            do {
                let (data, response, _) = try await boundedData(from: components.url!)
                let html = String(decoding: data, as: UTF8.self)
                let results = DuckDuckGoParser.parse(html, limit: count)
                guard !results.isEmpty else {
                    failures.append(
                        "\(response.url?.host ?? "DuckDuckGo") returned HTTP "
                            + "\(response.statusCode) but no parseable results"
                    )
                    continue
                }
                let content = results.enumerated().map { index, result in
                    "\(index + 1). \(result.title)\n\(result.url)\n\(result.snippet)"
                }.joined(separator: "\n\n")
                let links = results.map { SourceLink(title: $0.title, url: $0.url) }
                return ToolResult(
                    content: String(content.prefix(24_000)),
                    summary: "Found \(results.count) web results",
                    sources: links
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        throw WebToolError.search(failures.joined(separator: " Fallback: "))
    }

    public func fetch(url rawURL: String) async throws -> ToolResult {
        let url = try URLSafety.validate(rawURL)
        let (temporaryFile, response) = try await downloadedFile(from: url)
        defer { try? FileManager.default.removeItem(at: temporaryFile) }
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard contentType.isEmpty
                || contentType.contains("text")
                || contentType.contains("json")
                || contentType.contains("xml")
        else {
            throw WebToolError.invalidResponse
        }
        let extracted = try Self.extractBoundedText(
            from: temporaryFile,
            contentType: contentType,
            maximumCharacters: 30_000
        )
        let bounded = extracted.text
        guard !bounded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WebToolError.invalidResponse
        }
        let finalURL = response.url?.absoluteString ?? rawURL
        let fileSize = (try? temporaryFile.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize) ?? 0
        return ToolResult(
            content: bounded,
            summary: [
                "Fetched \(bounded.count) characters",
                ByteCountFormatter.string(
                    fromByteCount: Int64(fileSize),
                    countStyle: .file
                ) + " downloaded via temporary file",
                extracted.truncated
                    ? "model text truncated at 30K characters"
                    : nil
            ].compactMap { $0 }.joined(separator: " · "),
            sources: [SourceLink(title: response.url?.host ?? "Source", url: finalURL)]
        )
    }

    private func downloadedFile(
        from url: URL
    ) async throws -> (URL, HTTPURLResponse) {
        _ = try URLSafety.validate(url)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 LocalChat/0.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue(
            "text/html,application/xhtml+xml,text/plain,application/json",
            forHTTPHeaderField: "Accept"
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = max(timeout, 60)
        configuration.httpMaximumConnectionsPerHost = 2
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (temporaryFile, rawResponse) = try await session.download(
                for: request,
                delegate: SafeRedirectDelegate()
            )
            guard let response = rawResponse as? HTTPURLResponse else {
                try? FileManager.default.removeItem(at: temporaryFile)
                throw WebToolError.invalidResponse
            }
            guard (200..<300).contains(response.statusCode) else {
                try? FileManager.default.removeItem(at: temporaryFile)
                throw WebToolError.httpStatus(
                    response.statusCode,
                    response.url?.host ?? url.host ?? "server"
                )
            }
            let ownedTemporaryFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("LocalChat-\(UUID().uuidString).download")
            try FileManager.default.moveItem(
                at: temporaryFile,
                to: ownedTemporaryFile
            )
            return (ownedTemporaryFile, response)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as WebToolError {
            throw error
        } catch let error as URLError {
            if error.code == .timedOut {
                throw WebToolError.timedOut
            }
            throw WebToolError.transport(error.localizedDescription)
        } catch {
            throw WebToolError.transport(error.localizedDescription)
        }
    }

    private func boundedData(
        from url: URL
    ) async throws -> (Data, HTTPURLResponse, Bool) {
        _ = try URLSafety.validate(url)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 LocalChat/0.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml,text/plain,application/json", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpMaximumConnectionsPerHost = 2
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, rawResponse) = try await session.bytes(
                for: request,
                delegate: SafeRedirectDelegate()
            )
            guard let response = rawResponse as? HTTPURLResponse else {
                throw WebToolError.invalidResponse
            }
            guard (200..<300).contains(response.statusCode) else {
                throw WebToolError.httpStatus(
                    response.statusCode,
                    response.url?.host ?? url.host ?? "server"
                )
            }
            var data = Data()
            data.reserveCapacity(min(Int(max(response.expectedContentLength, 0)), maximumBytes))
            var truncated = response.expectedContentLength > Int64(maximumBytes)
            for try await byte in bytes {
                if data.count == maximumBytes {
                    truncated = true
                    break
                }
                data.append(byte)
            }
            return (data, response, truncated)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as WebToolError {
            throw error
        } catch let error as URLError {
            if error.code == .timedOut {
                throw WebToolError.timedOut
            }
            throw WebToolError.transport(error.localizedDescription)
        } catch {
            throw WebToolError.transport(error.localizedDescription)
        }
    }

    static func extractBoundedText(
        from file: URL,
        contentType: String,
        maximumCharacters: Int
    ) throws -> (text: String, truncated: Bool) {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var output = ""
        var reachedEnd = false
        while output.count < maximumCharacters {
            guard let data = try handle.read(upToCount: 256_000),
                  !data.isEmpty else {
                reachedEnd = true
                break
            }
            let raw = String(decoding: data, as: UTF8.self)
            let chunk = contentType.contains("html")
                ? extractText(fromHTML: raw)
                : raw
            if !chunk.isEmpty {
                if !output.isEmpty { output.append(" ") }
                output.append(chunk)
            }
        }
        let truncated = !reachedEnd || output.count > maximumCharacters
        return (
            String(output.prefix(maximumCharacters)),
            truncated
        )
    }

    private static func extractText(fromHTML html: String) -> String {
        var text = html
        for pattern in [
            #"(?is)<script[^>]*>.*?</script>"#,
            #"(?is)<style[^>]*>.*?</style>"#,
            #"(?is)<noscript[^>]*>.*?</noscript>"#,
            #"(?is)<!--.*?-->"#,
            #"(?is)<[^>]+>"#
        ] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

#if !APP_STORE
public actor NodeSidecar {
    private var activeProcess: Process?

    public init() {}

    public func execute(action: String, url: String, selector: String? = nil) async throws -> ToolResult {
        _ = try URLSafety.validate(url)
        let sidecarURL = try locateSidecar()
        var payload: [String: String] = ["action": action, "url": url]
        if let selector { payload["selector"] = String(selector.prefix(500)) }
        let input = try JSONEncoder().encode(payload)

        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", sidecarURL.path]
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError
        activeProcess = process
        do {
            try process.run()
        } catch {
            activeProcess = nil
            throw WebToolError.unavailable("Node.js could not be started")
        }
        standardInput.fileHandleForWriting.write(input)
        try? standardInput.fileHandleForWriting.close()

        do {
            while process.isRunning {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            if process.isRunning { process.terminate() }
            activeProcess = nil
            throw CancellationError()
        }
        activeProcess = nil

        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = standardError.fileHandleForReading.readDataToEndOfFile()
        guard output.count <= 256_000 else { throw WebToolError.responseTooLarge }
        guard let object = try? JSONDecoder().decode(SidecarResponse.self, from: output) else {
            let detail = String(decoding: errorOutput.prefix(1_000), as: UTF8.self)
            throw WebToolError.unavailable(detail.isEmpty ? "sidecar returned no structured response" : detail)
        }
        guard object.ok, let result = object.result else {
            throw WebToolError.unavailable(object.error?.message ?? "browser automation failed")
        }
        let sources = result.links?.prefix(40).compactMap { link -> SourceLink? in
            guard let title = link.title, let url = link.url else { return nil }
            return SourceLink(title: String(title.prefix(120)), url: url)
        } ?? []
        var pieces: [String] = []
        if let title = result.title { pieces.append("Title: \(title)") }
        if let finalURL = result.finalURL { pieces.append("Final URL: \(finalURL)") }
        if let text = result.text { pieces.append(String(text.prefix(40_000))) }
        return ToolResult(
            content: pieces.joined(separator: "\n\n"),
            summary: action == "snapshot" ? "Captured browser snapshot" : "Extracted matching page text",
            sources: Array(sources)
        )
    }

    public func cancel() {
        if let process = activeProcess, process.isRunning {
            process.terminate()
        }
        activeProcess = nil
    }

    private func locateSidecar() throws -> URL {
        let fileManager = FileManager.default
        if let override = ProcessInfo.processInfo.environment["LOCAL_CHAT_TOOLS_PATH"] {
            let candidate = URL(fileURLWithPath: override).appendingPathComponent("web-tools.mjs")
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        if let resource = Bundle.main.resourceURL {
            let candidate = resource.appendingPathComponent("Tools/web-tools.mjs")
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        let sourceCandidate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tools/web-tools.mjs")
        if fileManager.fileExists(atPath: sourceCandidate.path) { return sourceCandidate }
        throw WebToolError.unavailable("the packaged Node sidecar is missing")
    }
}

private struct SidecarResponse: Decodable {
    struct ErrorBody: Decodable {
        let code: String?
        let message: String
    }

    struct Link: Decodable {
        let title: String?
        let url: String?
    }

    struct Result: Decodable {
        let title: String?
        let finalURL: String?
        let text: String?
        let links: [Link]?
    }

    let ok: Bool
    let result: Result?
    let error: ErrorBody?
}
#endif

public actor WebToolExecutor {
    private let directClient: DirectWebClient
    #if !APP_STORE
    private let sidecar: NodeSidecar
    #endif
    private let localContext: LocalContextProvider
    private let localSearch: any LocalSearching

    #if APP_STORE
    public init(
        directClient: DirectWebClient = DirectWebClient(),
        localContext: LocalContextProvider = LocalContextProvider(),
        localSearch: any LocalSearching = LocalSearchProvider()
    ) {
        self.directClient = directClient
        self.localContext = localContext
        self.localSearch = localSearch
    }
    #else
    public init(
        directClient: DirectWebClient = DirectWebClient(),
        sidecar: NodeSidecar = NodeSidecar(),
        localContext: LocalContextProvider = LocalContextProvider(),
        localSearch: any LocalSearching = LocalSearchProvider()
    ) {
        self.directClient = directClient
        self.sidecar = sidecar
        self.localContext = localContext
        self.localSearch = localSearch
    }
    #endif

    public func execute(_ invocation: ToolInvocation) async throws -> ToolResult {
        switch invocation.name {
        case "local_search":
            guard let query = invocation.arguments["query"]?.stringValue else {
                throw LocalContextError.localSearchUnavailable("missing query")
            }
            return try await localSearch.search(
                query: query,
                radiusKilometers: invocation.arguments["radius_km"]?.numberValue ?? 5,
                maximumResults: invocation.arguments["max_results"]?.integerValue ?? 8,
                usesChineseLabels: invocation.arguments["response_language"]?.stringValue == "zh"
            )
        case "local_context":
            guard let values = invocation.arguments["fields"]?.arrayValue else {
                throw LocalContextError.invalidFields
            }
            let names = values.compactMap(\.stringValue)
            let fields = names.compactMap(LocalContextField.init(rawValue:))
            guard fields.count == names.count, !fields.isEmpty else {
                throw LocalContextError.invalidFields
            }
            var seen = Set<LocalContextField>()
            let unique = fields.filter { seen.insert($0).inserted }
            return try await localContext.collect(fields: unique)
                #if !APP_STORE_RELEASE
                case "code_interpreter":
            guard let expression = invocation.arguments["expression"]?.stringValue,
                  !expression.isEmpty else {
                throw CodeInterpreterError.invalidExpression("missing expression")
            }
            let output = try CodeInterpreterTool.evaluate(expression)
            return ToolResult(
                content: output,
                summary: "Evaluated a local JavaScriptCore expression"
            )
        #endif
        case "web_search":
            guard let query = invocation.arguments["query"]?.stringValue,
                  !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw WebToolError.invalidResponse }
            let maximum = invocation.arguments["max_results"]?.integerValue ?? 5
            return try await directClient.search(query: query, maximumResults: maximum)
        case "fetch_url":
            guard let url = invocation.arguments["url"]?.stringValue else {
                throw WebToolError.invalidURL("missing url")
            }
            #if APP_STORE
            return try await directClient.fetch(url: url)
            #else
            do {
                let result = try await directClient.fetch(url: url)
                if result.content.count >= 200 {
                    return result
                }
                return try await sidecar.execute(action: "snapshot", url: url)
            } catch WebToolError.invalidResponse {
                return try await sidecar.execute(action: "snapshot", url: url)
            }
            #endif
        case "browser_snapshot":
            #if APP_STORE
            throw WebToolError.unavailable("browser automation is not included in the App Store build")
            #else
            guard let url = invocation.arguments["url"]?.stringValue else {
                throw WebToolError.invalidURL("missing url")
            }
            return try await sidecar.execute(action: "snapshot", url: url)
            #endif
        case "browser_extract":
            #if APP_STORE
            throw WebToolError.unavailable("browser automation is not included in the App Store build")
            #else
            guard let url = invocation.arguments["url"]?.stringValue,
                  let selector = invocation.arguments["selector"]?.stringValue,
                  !selector.isEmpty
            else { throw WebToolError.invalidResponse }
            return try await sidecar.execute(action: "extract", url: url, selector: selector)
            #endif
        default:
            throw WebToolError.unavailable("unsupported tool \(invocation.name)")
        }
    }

    public func cancel() async {
        #if !APP_STORE
        await sidecar.cancel()
        #endif
    }
}
