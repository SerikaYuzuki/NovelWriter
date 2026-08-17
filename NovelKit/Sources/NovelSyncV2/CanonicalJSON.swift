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
        var parser = try Parser(data)
        let parsed = try parser.parse()
        return try render(parsed)
    }

    public static func validate(_ data: Data) throws {
        var parser = try Parser(data)
        let parsed = try parser.parse()
        guard try render(parsed) == data else { throw CanonicalJSONError.nonCanonical }
    }

    /// Validates an object and returns its parsed form for schema validation.
    static func parseObject(_ data: Data) throws -> Value {
        var parser = try Parser(data)
        let value = try parser.parse()
        guard case .object = value else { throw CanonicalJSONError.topLevelValueNotObject }
        guard try render(value) == data else { throw CanonicalJSONError.nonCanonical }
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
            guard case let .object(pairs) = self else { return nil }
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
            let sorted = pairs.sorted { $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) }
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
            case 8: output.append(contentsOf: "\\b".utf8)
            case 9: output.append(contentsOf: "\\t".utf8)
            case 10: output.append(contentsOf: "\\n".utf8)
            case 12: output.append(contentsOf: "\\f".utf8)
            case 13: output.append(contentsOf: "\\r".utf8)
            case 0 ... 31:
                output.append(contentsOf: String(format: "\\u%04x", scalar.value).utf8)
            case 34: output.append(contentsOf: "\\\"".utf8)
            case 92: output.append(contentsOf: "\\\\".utf8)
            default: output.append(contentsOf: String(scalar).utf8)
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

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        init(_ data: Data) throws {
            guard String(data: data, encoding: .utf8) != nil else { throw CanonicalJSONError.invalidUTF8 }
            bytes = Array(data)
        }

        mutating func parse() throws -> Value {
            skipWhitespace()
            let result = try parseValue()
            skipWhitespace()
            guard index == bytes.count else { throw CanonicalJSONError.malformed }
            return result
        }

        mutating func parseValue() throws -> Value {
            guard let byte = peek else { throw CanonicalJSONError.malformed }
            switch byte {
            case 123: return try parseObject()
            case 91: return try parseArray()
            case 34: return try .string(parseString())
            case 45, 48 ... 57: return try parseNumber()
            case 116: try consume("true"); return .bool(true)
            case 102: try consume("false"); return .bool(false)
            case 110: try consume("null"); return .null
            default: throw CanonicalJSONError.malformed
            }
        }

        mutating func parseObject() throws -> Value {
            try expect(123)
            skipWhitespace()
            var pairs: [(String, Value)] = []
            var keys = Set<String>()
            if peek == 125 {
                index += 1; return .object(pairs)
            }
            while true {
                skipWhitespace()
                guard peek == 34 else { throw CanonicalJSONError.malformed }
                let key = try parseString()
                guard keys.insert(key).inserted else { throw CanonicalJSONError.duplicateKey(key) }
                skipWhitespace(); try expect(58); skipWhitespace()
                try pairs.append((key, parseValue()))
                skipWhitespace()
                if peek == 125 {
                    index += 1; return .object(pairs)
                }
                try expect(44)
            }
        }

        mutating func parseArray() throws -> Value {
            try expect(91); skipWhitespace()
            var values: [Value] = []
            if peek == 93 {
                index += 1; return .array(values)
            }
            while true {
                try values.append(parseValue()); skipWhitespace()
                if peek == 93 {
                    index += 1; return .array(values)
                }
                try expect(44); skipWhitespace()
            }
        }

        mutating func parseString() throws -> String {
            try expect(34)
            var scalars: [UnicodeScalar] = []
            while let byte = peek {
                index += 1
                if byte == 34 {
                    return String(String.UnicodeScalarView(scalars))
                }
                if byte == 92 {
                    guard let escape = peek else { throw CanonicalJSONError.malformed }
                    index += 1
                    switch escape {
                    case 34: scalars.append("\"")
                    case 92: scalars.append("\\")
                    case 47: scalars.append("/")
                    case 98: scalars.append("\u{8}")
                    case 102: scalars.append("\u{c}")
                    case 110: scalars.append("\n")
                    case 114: scalars.append("\r")
                    case 116: scalars.append("\t")
                    case 117:
                        let scalar = try parseUnicodeEscape()
                        guard !(0xD800 ... 0xDFFF).contains(scalar.value) else { throw CanonicalJSONError.malformed }
                        scalars.append(scalar)
                    default: throw CanonicalJSONError.malformed
                    }
                } else {
                    guard byte >= 0x20 else { throw CanonicalJSONError.malformed }
                    let start = index - 1
                    while index < bytes.count, bytes[index] >= 0x20, bytes[index] != 34, bytes[index] != 92 {
                        index += 1
                    }
                    guard let chunk = String(bytes: bytes[start ..< index], encoding: .utf8) else { throw CanonicalJSONError.invalidUTF8 }
                    scalars.append(contentsOf: chunk.unicodeScalars)
                }
            }
            throw CanonicalJSONError.malformed
        }

        mutating func parseUnicodeEscape() throws -> UnicodeScalar {
            guard index + 4 <= bytes.count else { throw CanonicalJSONError.malformed }
            let text = String(bytes: bytes[index ..< (index + 4)], encoding: .ascii)
            index += 4
            guard let value = text.flatMap({ UInt32($0, radix: 16) }), let scalar = UnicodeScalar(value) else {
                throw CanonicalJSONError.malformed
            }
            return scalar
        }

        mutating func parseNumber() throws -> Value {
            let start = index
            if peek == 45 {
                index += 1
            }
            guard let first = peek else { throw CanonicalJSONError.malformed }
            if first == 48 {
                index += 1
                if let next = peek, next >= 48, next <= 57 {
                    throw CanonicalJSONError.malformed
                }
            } else if first >= 49, first <= 57 {
                while let byte = peek, byte >= 48, byte <= 57 {
                    index += 1
                }
            } else {
                throw CanonicalJSONError.malformed
            }
            if let next = peek, next == 46 || next == 101 || next == 69 {
                throw CanonicalJSONError.unsupportedNumber
            }
            let text = String(bytes: bytes[start ..< index], encoding: .ascii)!
            guard let number = Int64(text), abs(number) <= 9_007_199_254_740_991 else {
                throw CanonicalJSONError.unsafeInteger
            }
            return .number(number)
        }

        mutating func consume(_ string: String) throws {
            let expected = Array(string.utf8)
            guard bytes[index ..< min(index + expected.count, bytes.count)].elementsEqual(expected) else { throw CanonicalJSONError.malformed }
            index += expected.count
        }

        mutating func expect(_ byte: UInt8) throws {
            guard peek == byte else { throw CanonicalJSONError.malformed }
            index += 1
        }

        mutating func skipWhitespace() {
            while let byte = peek, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                index += 1
            }
        }

        var peek: UInt8? {
            index < bytes.count ? bytes[index] : nil
        }
    }
}
