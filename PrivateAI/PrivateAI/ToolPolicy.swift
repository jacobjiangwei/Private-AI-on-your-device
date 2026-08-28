import Foundation

public enum ToolPolicy {
    enum InvocationValidationError: LocalizedError {
        case invalidArguments(String)
        case blockedLocationActivation
        case externalAttachmentRetrievalNotAuthorized

        var errorDescription: String? {
            switch self {
            case .invalidArguments(let action):
                String(localized: "The local model returned invalid arguments for \(action).")
            case .blockedLocationActivation:
                String(localized: "Location access was blocked because the request did not authorize current location use.")
            case .externalAttachmentRetrievalNotAuthorized:
                String(localized: "External retrieval was blocked because the user did not ask to send attachment-derived information to the web.")
            }
        }
    }

    static let modelActionToolNames: Set<String> = {
        var names: Set<String> = [
            "local_context", "local_search", "web_search",
            "fetch_url", "code_interpreter"
        ]
        #if !APP_STORE
        names.formUnion(["browser_snapshot", "browser_extract"])
        #endif
        return names
    }()

    static func validateModelInvocation(
        _ invocation: ToolInvocation,
        for prompt: String,
        hasAttachments: Bool = false
    ) throws -> ToolInvocation {
        guard modelActionToolNames.contains(invocation.name) else {
            throw InvocationValidationError.invalidArguments(invocation.name)
        }
        let arguments = invocation.arguments
        switch invocation.name {
        case "local_search":
            guard allowsCurrentLocationUse(for: prompt),
                  let query = arguments["query"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !query.isEmpty,
                  query.count <= 120,
                  !query.contains("\n"),
                  !containsLocalFilePath(query),
                  URL(string: query)?.scheme == nil,
                  Set(arguments.keys).isSubset(of: ["query", "radius_km", "max_results"])
            else {
                if !allowsCurrentLocationUse(for: prompt) {
                    throw InvocationValidationError.blockedLocationActivation
                }
                throw InvocationValidationError.invalidArguments(invocation.name)
            }
            let radius = min(max(arguments["radius_km"]?.numberValue ?? 5, 0.5), 50)
            let maximum = min(max(arguments["max_results"]?.integerValue ?? 8, 1), 12)
            return ToolInvocation(
                id: invocation.id,
                name: invocation.name,
                arguments: [
                    "query": .string(query),
                    "radius_km": .number(radius),
                    "max_results": .number(Double(maximum)),
                    "response_language": .string(
                        prompt.range(of: #"\p{Han}"#, options: .regularExpression) != nil
                            ? "zh"
                            : "en"
                    )
                ]
            )

        case "local_context":
            guard Set(arguments.keys) == ["fields"],
                  let values = arguments["fields"]?.arrayValue else {
                throw InvocationValidationError.invalidArguments(invocation.name)
            }
            let names = values.compactMap(\.stringValue)
            let decodedFields = names.compactMap(LocalContextField.init(rawValue:))
            guard names.count == values.count,
                  decodedFields.count == names.count,
                  !decodedFields.isEmpty else {
                throw InvocationValidationError.invalidArguments(invocation.name)
            }
            var seen = Set<LocalContextField>()
            let fields = decodedFields.filter {
                seen.insert($0).inserted
            }
            if fields.contains(.location), !allowsCurrentLocationUse(for: prompt) {
                throw InvocationValidationError.blockedLocationActivation
            }
            return ToolInvocation(
                id: invocation.id,
                name: invocation.name,
                arguments: [
                    "fields": .array(fields.map { .string($0.rawValue) })
                ]
            )

        case "web_search":
            if hasAttachments, !allowsAttachmentDerivedExternalRetrieval(for: prompt) {
                throw InvocationValidationError.externalAttachmentRetrievalNotAuthorized
            }
            guard Set(arguments.keys).isSubset(of: ["query", "max_results"]),
                  let query = arguments["query"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !query.isEmpty,
                  query.count <= 300,
                  !containsLocalFilePath(query) else {
                throw InvocationValidationError.invalidArguments(invocation.name)
            }
            let maximum = min(max(arguments["max_results"]?.integerValue ?? 5, 1), 8)
            return ToolInvocation(
                id: invocation.id,
                name: invocation.name,
                arguments: [
                    "query": .string(query),
                    "max_results": .number(Double(maximum))
                ]
            )

        case "fetch_url", "browser_snapshot":
            if hasAttachments, !allowsAttachmentDerivedExternalRetrieval(for: prompt) {
                throw InvocationValidationError.externalAttachmentRetrievalNotAuthorized
            }
            guard Set(arguments.keys) == ["url"],
                  let rawURL = arguments["url"]?.stringValue else {
                throw InvocationValidationError.invalidArguments(invocation.name)
            }
            _ = try URLSafety.validate(rawURL, resolveDNS: false)
            return invocation

        case "browser_extract":
            if hasAttachments, !allowsAttachmentDerivedExternalRetrieval(for: prompt) {
                throw InvocationValidationError.externalAttachmentRetrievalNotAuthorized
            }
            guard Set(arguments.keys) == ["url", "selector"],
                  let rawURL = arguments["url"]?.stringValue,
                  let selector = arguments["selector"]?.stringValue,
                  !selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  selector.count <= 200 else {
                throw InvocationValidationError.invalidArguments(invocation.name)
            }
            _ = try URLSafety.validate(rawURL, resolveDNS: false)
            return invocation

        case "code_interpreter":
            guard Set(arguments.keys) == ["expression"],
                  let expression = arguments["expression"]?.stringValue,
                  !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                    expression.count <= 500,
                                    isDeterministicComputation(expression) else {
                throw InvocationValidationError.invalidArguments(invocation.name)
            }
            return invocation

        default:
            throw InvocationValidationError.invalidArguments(invocation.name)
        }
    }

    static func unsupportedToolClaim(
        in answer: String,
        successfulTools: Set<String>
    ) -> String? {
        let normalized = answer.lowercased()
        let claims: [(Set<String>, [String])] = [
            (["local_search"], [
                "apple maps", "苹果地图", "地图搜索结果", "附近有以下", "你附近有"
            ]),
            (["web_search", "fetch_url", "browser_snapshot", "browser_extract"], [
                "according to the web search", "根据网页搜索", "根据搜索结果"
            ]),
            (["local_context"], [
                "macos core location", "core location", "根据你的定位", "你当前的定位"
            ])
        ]
        for (requiredTools, phrases) in claims
        where requiredTools.isDisjoint(with: successfulTools)
            && phrases.contains(where: normalized.contains) {
            return "The answer claimed tool-backed information without a successful tool result."
        }
        return nil
    }

    public static func shouldRequestJSONFormat(for prompt: String) -> Bool {
        let normalized = promptByRemovingLocalFilePaths(prompt).lowercased()
        let jsonSignals = [
            "json object", "json only", "only json", "valid json",
            "strict json", "json schema", "仅返回json", "只返回json",
            "json对象", "json 格式", "json格式"
        ]
        return jsonSignals.contains(where: normalized.contains)
    }

    public static func localFilePaths(in prompt: String) -> [String] {
        localFilePathExpression.matches(
            in: prompt,
            range: NSRange(prompt.startIndex..., in: prompt)
        ).compactMap { match in
            Range(match.range, in: prompt).map { String(prompt[$0]) }
        }
    }

    public static func containsLocalFilePath(_ prompt: String) -> Bool {
        !localFilePaths(in: prompt).isEmpty
    }

    static func blocksLocationActivation(for prompt: String) -> Bool {
        let normalized = promptByRemovingLocalFilePaths(prompt).lowercased()
        if isMetaLocalContextRequest(normalized) { return true }
        let patterns = [
            #"\b(?:translate|rewrite|quote|explain|define|analyze).{0,60}(?:near me|nearby|closest|around me|local search)\b"#,
            #"\b(?:do not|don't|dont|never)\s+(?:access|use|request|read|share|search).{0,40}(?:location|near me|nearby|around me)\b"#,
            #"\b(?:near me|nearby|around me).{0,30}(?:in|on).{0,10}(?:this )?(?:screenshot|image|photo|map|document|message)\b"#,
            #"(?:翻译|改写|解释|引用|分析).{0,30}(?:附近|周边|离我最近|本地搜索)"#,
            #"(?:不要|别|禁止).{0,20}(?:获取|访问|使用|读取|分享|搜索)?.{0,12}(?:我的位置|定位|附近|周边)"#,
            #"(?:截图|图片|照片|地图|文档|消息)(?:里|中|上).{0,20}(?:附近|周边|离我最近)"#
        ]
        return patterns.contains {
            normalized.range(of: $0, options: .regularExpression) != nil
        }
    }

    private static func allowsCurrentLocationUse(for prompt: String) -> Bool {
        !blocksLocationActivation(for: prompt)
    }

    private static func allowsAttachmentDerivedExternalRetrieval(
        for prompt: String
    ) -> Bool {
        let normalized = promptByRemovingLocalFilePaths(prompt).lowercased()
        let explicitSignals = [
            "search the web", "search online", "look up online", "browse the web",
            "check online", "verify online", "compare with current", "compare against current",
            "联网搜索", "上网搜索", "网上查", "联网查", "搜索网页", "查一下最新",
            "对比最新", "和网上", "与网上"
        ]
        return explicitSignals.contains(where: normalized.contains)
    }

    private static func isDeterministicComputation(_ expression: String) -> Bool {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(
            of: #"^(['\"]).*\1$"#,
            options: .regularExpression
        ) != nil {
            return false
        }
        let forbiddenStringTransforms = [
            #"(?i)\.replace(?:All)?\s*\("#,
            #"(?i)\.to(?:Upper|Lower)Case\s*\("#,
            #"(?i)\b(?:translate|rewrite)\b"#
        ]
        if forbiddenStringTransforms.contains(where: {
            trimmed.range(of: $0, options: .regularExpression) != nil
        }) {
            return false
        }
        let computationSignals = [
            #"\d\s*[+\-*/%×÷]\s*\d"#,
            #"(?i)\b(?:sum|mean|median|min|max|sort|unique|count)\s*\("#,
            #"(?i)\bJSON\.(?:parse|stringify)\s*\("#,
            #"^[\[\{].*[\]\}]"#
        ]
        return computationSignals.contains {
            trimmed.range(of: $0, options: .regularExpression) != nil
        }
    }

    public static func promptByRemovingLocalFilePaths(_ prompt: String) -> String {
        localFilePathExpression.stringByReplacingMatches(
            in: prompt,
            range: NSRange(prompt.startIndex..., in: prompt),
            withTemplate: ""
        )
    }

    private static let localFilePathExpression = try! NSRegularExpression(
        pattern: #"(?im)(?<![A-Za-z0-9:])(?:(?:file://)?(?:/(?:Users|Volumes|private|tmp|Applications|Library|System|opt|usr|var|etc)|~)/[^\n\r\"'`]+?(?=\s*$)|(?:file://)?(?:/(?:Users|Volumes|private|tmp|Applications|Library|System|opt|usr|var|etc)|~)/(?:[^\n\r\"'`]+?)\.[A-Za-z0-9][A-Za-z0-9._+\-]{0,31}\b)"#
    )

    private static func isMetaLocalContextRequest(_ normalized: String) -> Bool {
        let patterns = [
            #"\b(?:do not|don't|dont|never)\s+(?:access|use|request|read|share).{0,30}(?:my location|where i am)\b"#,
            #"\b(?:translate|rewrite|quote|explain|define).{0,40}(?:where am i|my location)\b"#,
            #"\b(?:find|show|tell me).{0,30}(?:where i am|my location).{0,30}(?:mentioned|written|said).{0,20}(?:document|message|chat)"#,
            #"\b(?:where am i|my location).{0,20}(?:in|on).{0,10}(?:this )?(?:screenshot|image|photo|map|document)\b"#,
            #"(?:不要|别|禁止).{0,12}(?:获取|访问|使用|读取|分享)?.{0,8}(?:我的位置|定位)"#,
            #"(?:翻译|改写|解释|引用).{0,20}(?:我在哪|我在哪里|我的位置)"#,
            #"我在哪(?:个|篇|份|条|段|句|些)(?:文档|消息|对话|段落|句子).{0,20}"#,
            #"我在哪里(?:提到|写到|说过|看到)"#,
            #"(?:截图|图片|照片|地图|文档)(?:里|中|上).{0,12}我在哪"#,
            #"我在哪.{0,8}(?:截图|图片|照片|地图|文档)(?:里|中|上)"#
        ]
        return patterns.contains {
            normalized.range(of: $0, options: .regularExpression) != nil
        }
    }

}
