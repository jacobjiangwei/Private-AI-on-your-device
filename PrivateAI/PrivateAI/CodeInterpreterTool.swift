#if !APP_STORE_RELEASE
import Foundation
import JavaScriptCore

public enum CodeInterpreterError: LocalizedError, Sendable {
    case invalidExpression(String)
    case executionFailed(String)
    case resultTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidExpression(let detail):
            "Code interpreter rejected the expression: \(detail)"
        case .executionFailed(let detail):
            "Code interpreter failed: \(detail)"
        case .resultTooLarge:
            "Code interpreter result exceeded 100 KB."
        }
    }
}

public enum CodeInterpreterTool {
    private static let maximumExpressionCharacters = 8_000
    private static let maximumResultBytes = 100_000

    public static func evaluate(_ expression: String) throws -> String {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        try validate(trimmed)
        guard let context = JSContext() else {
            throw CodeInterpreterError.executionFailed("JavaScriptCore is unavailable")
        }
        var exceptionMessage: String?
        context.exceptionHandler = { _, exception in
            exceptionMessage = exception?.toString() ?? "Unknown JavaScript error"
        }
        context.evaluateScript(Self.prelude)
        guard exceptionMessage == nil else {
            throw CodeInterpreterError.executionFailed(exceptionMessage ?? "Prelude failed")
        }
        let value = context.evaluateScript("JSON.stringify((\(trimmed)))")
        if let exceptionMessage {
            throw CodeInterpreterError.executionFailed(exceptionMessage)
        }
        guard let json = value, !json.isUndefined, !json.isNull,
              let text = json.toString(),
              let data = text.data(using: .utf8)
        else {
            throw CodeInterpreterError.executionFailed("Expression returned no serializable value")
        }
        guard data.count <= maximumResultBytes else {
            throw CodeInterpreterError.resultTooLarge
        }
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if let string = object as? String {
            return string
        }
        if JSONSerialization.isValidJSONObject(object) {
            let formatted = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            return String(decoding: formatted, as: UTF8.self)
        }
        if object is NSNull {
            return "null"
        }
        return String(describing: object)
    }

    private static func validate(_ expression: String) throws {
        guard !expression.isEmpty else {
            throw CodeInterpreterError.invalidExpression("expression is empty")
        }
        guard expression.count <= maximumExpressionCharacters else {
            throw CodeInterpreterError.invalidExpression("expression exceeds 8,000 characters")
        }
        let forbiddenPatterns = [
            #";"#,
            #"=>"#,
            #"(?i)\b(?:while|for|do|function|class|new|import|export|await|yield|eval)\b"#,
            #"(?i)\b(?:globalThis|window|document|process|require|fetch|XMLHttpRequest)\b"#,
            #"(?i)\b(?:constructor|prototype|__proto__|WebAssembly|Atomics|SharedArrayBuffer)\b"#,
            #"(?i)\.repeat\s*\("#,
            #"\+\+|--"#,
            #"(?<![=!<>])=(?!=)"#
        ]
        let source = strippingStringContents(from: expression)
        for pattern in forbiddenPatterns
            where source.range(of: pattern, options: .regularExpression) != nil {
            throw CodeInterpreterError.invalidExpression(
                "statements, mutation, loops, functions, dynamic code, and I/O are not allowed"
            )
        }
    }

    private static func strippingStringContents(from source: String) -> String {
        var output = ""
        var quote: Character?
        var escaped = false
        for character in source {
            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                    output.append(character)
                } else {
                    output.append(" ")
                }
            } else if character == "\"" || character == "'" {
                quote = character
                output.append(character)
            } else {
                output.append(character)
            }
        }
        return output
    }

    private static let prelude = """
    const __numbers = (values) => {
      if (!Array.isArray(values) || values.length > 10000) {
        throw new Error("Expected an array with at most 10,000 values");
      }
      const result = values.map(Number);
      if (result.some(value => !Number.isFinite(value))) {
        throw new Error("Array contains a non-finite number");
      }
      return result;
    };
    const sum = values => __numbers(values).reduce((total, value) => total + value, 0);
    const mean = values => {
      const items = __numbers(values);
      return items.length ? sum(items) / items.length : null;
    };
    const median = values => {
      const items = __numbers(values).slice().sort((a, b) => a - b);
      if (!items.length) return null;
      const middle = Math.floor(items.length / 2);
      return items.length % 2 ? items[middle] : (items[middle - 1] + items[middle]) / 2;
    };
    const min = values => Math.min(...__numbers(values));
    const max = values => Math.max(...__numbers(values));
    const sort = values => __numbers(values).slice().sort((a, b) => a - b);
    const unique = values => {
      if (!Array.isArray(values) || values.length > 10000) {
        throw new Error("Expected an array with at most 10,000 values");
      }
      return [...new Set(values)];
    };
    const count = values => {
      if (!Array.isArray(values) && typeof values !== "string") {
        throw new Error("Expected an array or string");
      }
      return values.length;
    };
    globalThis.eval = undefined;
    globalThis.Function = undefined;
    Object.freeze(Math);
    Object.freeze(JSON);
    """
}
#endif
