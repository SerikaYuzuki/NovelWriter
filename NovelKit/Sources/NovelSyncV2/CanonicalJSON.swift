import Foundation

/// Errors raised when the v2 wire representation is not an exact JCS value.
public enum CanonicalJSONError: Error, Equatable, Sendable {
    case invalidUTF8
    case malformed
    case duplicateKey(String)
    case nonCanonical
    case unsupportedNumber
    case unsafeInteger
    case topLevelValueNotObject
    case inputTooLarge
    case nestingTooDeep
}

/// The small JSON surface used by Snapshot Sync v2.
///
/// v2 deliberately accepts only the JSON values needed by its schemas. In
/// particular, numbers are safe integers. This avoids allowing a Foundation
/// JSON round-trip to change an identity byte sequence.
public enum CanonicalJSON {
    public static func encode(_ value: any Encodable) throws -> Data {
        let encoder = JSONEncoder()
        let data = try encoder.encode(ErasedEncodable(value))
        var parser = try CanonicalJSONParser(
            data,
            maxBytes: SnapshotSyncV2Limits.maxCommandBytes
        )
        let parsed = try parser.parse()
        return try render(parsed)
    }

    public static func validate(_ data: Data) throws {
        var parser = try CanonicalJSONParser(
            data,
            maxBytes: SnapshotSyncV2Limits.maxCommandBytes
        )
        let parsed = try parser.parse()
        guard try render(parsed) == data else {
            throw CanonicalJSONError.nonCanonical
        }
    }

    /// Validates an object and returns its parsed form for schema validation.
    static func parseObject(
        _ data: Data,
        maxBytes: Int = SnapshotSyncV2Limits.maxCommandBytes,
        maxDepth: Int = SnapshotSyncV2Limits.maxCanonicalJSONDepth
    ) throws -> Value {
        var parser = try CanonicalJSONParser(
            data,
            maxBytes: maxBytes,
            maxDepth: maxDepth
        )
        let value = try parser.parse()
        guard case .object = value else {
            throw CanonicalJSONError.topLevelValueNotObject
        }
        guard try render(value) == data else {
            throw CanonicalJSONError.nonCanonical
        }
        return value
    }

    indirect enum Value: Sendable {
        case object([(String, Value)])
        case array([Value])
        case string(String)
        case number(Int64)
        case bool(Bool)
        case null

        var objectDictionary: [String: Value]? {
            guard case let .object(pairs) = self else {
                return nil
            }
            return Dictionary(pairs, uniquingKeysWith: { first, _ in first })
        }
    }

    static func render(_ value: Value) throws -> Data {
        var output = Data()
        try append(value, to: &output)
        return output
    }

    static func object(_ fields: [(String, Value)]) -> Data {
        (try? render(.object(fields))) ?? Data()
    }

    private static func append(_ value: Value, to output: inout Data) throws {
        switch value {
        case let .object(pairs):
            output.append(123)
            // RFC 8785 orders property names by their UTF-16 code units, not
            // by UTF-8 bytes or Unicode scalar values.
            let sorted = pairs.sorted {
                $0.0.utf16.lexicographicallyPrecedes($1.0.utf16)
            }
            for (index, pair) in sorted.enumerated() {
                if index != 0 {
                    output.append(44)
                }
                appendString(pair.0, to: &output)
                output.append(58)
                try append(pair.1, to: &output)
            }
            output.append(125)
        case let .array(values):
            output.append(91)
            for (index, child) in values.enumerated() {
                if index != 0 {
                    output.append(44)
                }
                try append(child, to: &output)
            }
            output.append(93)
        case let .string(string):
            appendString(string, to: &output)
        case let .number(number):
            output.append(contentsOf: String(number).utf8)
        case let .bool(value):
            output.append(contentsOf: (value ? "true" : "false").utf8)
        case .null:
            output.append(contentsOf: "null".utf8)
        }
    }

    private static func appendString(_ string: String, to output: inout Data) {
        output.append(34)
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 8:
                output.append(contentsOf: "\\b".utf8)
            case 9:
                output.append(contentsOf: "\\t".utf8)
            case 10:
                output.append(contentsOf: "\\n".utf8)
            case 12:
                output.append(contentsOf: "\\f".utf8)
            case 13:
                output.append(contentsOf: "\\r".utf8)
            case 0 ... 31:
                output.append(
                    contentsOf: String(format: "\\u%04x", scalar.value).utf8
                )
            case 34:
                output.append(contentsOf: "\\\"".utf8)
            case 92:
                output.append(contentsOf: "\\\\".utf8)
            default:
                output.append(contentsOf: String(scalar).utf8)
            }
        }
        output.append(34)
    }

    private struct ErasedEncodable: Encodable {
        let value: any Encodable

        init(_ value: any Encodable) {
            self.value = value
        }

        func encode(to encoder: Encoder) throws {
            try value.encode(to: encoder)
        }
    }
}
