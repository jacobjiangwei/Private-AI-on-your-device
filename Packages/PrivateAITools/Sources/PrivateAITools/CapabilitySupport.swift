import Foundation
import LLMCore

public enum CapabilityToolError: Error, Equatable, LocalizedError, Sendable {
    case missingArgument(String)
    case invalidArgument(String)
    case unexpectedArguments([String])
    case unsupportedAction(String)

    public var errorDescription: String? {
        switch self {
        case .missingArgument(let name):
            "Missing required argument '\(name)'."
        case .invalidArgument(let name):
            "Argument '\(name)' has an invalid value."
        case .unexpectedArguments(let names):
            "Unexpected arguments: \(names.joined(separator: ", "))."
        case .unsupportedAction(let action):
            "Unsupported action '\(action)'."
        }
    }
}

struct CapabilityArguments {
    let values: [String: JSONValue]

    func requireOnly(_ allowed: Set<String>) throws {
        let unexpected = values.keys.filter { !allowed.contains($0) }.sorted()
        guard unexpected.isEmpty else {
            throw CapabilityToolError.unexpectedArguments(unexpected)
        }
    }

    func requiredString(_ name: String, maximumBytes: Int = 8_192) throws -> String {
        guard let rawValue = values[name] else {
            throw CapabilityToolError.missingArgument(name)
        }
        guard let value = rawValue.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.utf8.count <= maximumBytes
        else {
            throw CapabilityToolError.invalidArgument(name)
        }
        return value
    }

    func optionalString(_ name: String, maximumBytes: Int = 8_192) throws -> String? {
        guard values[name] != nil else {
            return nil
        }
        return try requiredString(name, maximumBytes: maximumBytes)
    }

    func optionalInteger(_ name: String, range: ClosedRange<Int>) throws -> Int? {
        guard let rawValue = values[name] else {
            return nil
        }
        guard let value = rawValue.integerValue, range.contains(value) else {
            throw CapabilityToolError.invalidArgument(name)
        }
        return value
    }

    func optionalNumber(_ name: String, range: ClosedRange<Double>) throws -> Double? {
        guard let rawValue = values[name] else {
            return nil
        }
        guard case .number(let value) = rawValue, range.contains(value) else {
            throw CapabilityToolError.invalidArgument(name)
        }
        return value
    }
}

func encodeToolResult(_ result: JSONValue) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(result), as: UTF8.self)
}

func objectSchema(
    properties: [String: JSONValue],
    required: [String] = []
) -> JSONValue {
    var schema: [String: JSONValue] = [
        "type": .string("object"),
        "properties": .object(properties),
        "additionalProperties": .bool(false)
    ]
    if !required.isEmpty {
        schema["required"] = .array(required.map(JSONValue.string))
    }
    return .object(schema)
}

func stringSchema(
    description: String,
    values: [String]? = nil
) -> JSONValue {
    var schema: [String: JSONValue] = [
        "type": .string("string"),
        "description": .string(description)
    ]
    if let values {
        schema["enum"] = .array(values.map(JSONValue.string))
    }
    return .object(schema)
}

func integerSchema(description: String, range: ClosedRange<Int>) -> JSONValue {
    .object([
        "type": .string("integer"),
        "description": .string(description),
        "minimum": .number(Double(range.lowerBound)),
        "maximum": .number(Double(range.upperBound))
    ])
}

func numberSchema(description: String, range: ClosedRange<Double>) -> JSONValue {
    .object([
        "type": .string("number"),
        "description": .string(description),
        "minimum": .number(range.lowerBound),
        "maximum": .number(range.upperBound)
    ])
}