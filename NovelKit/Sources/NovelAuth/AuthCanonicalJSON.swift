import Foundation

public enum AuthCanonicalJSONError: Error, Equatable, Sendable {
    case invalidUTF8
    case byteOrderMark
    case invalidSyntax
    case duplicateKey
    case nonCanonical
    case unsafeNumber
    case invalidUnicode
}

public indirect enum AuthCanonicalJSONValue: Sendable {
    case object([(String, AuthCanonicalJSONValue)])
    case array([AuthCanonicalJSONValue])
    case string(String)
    case number(negative: Bool, magnitude: UInt64)
    case boolean(Bool)
    case null

    public var objectMembers: [(String, AuthCanonicalJSONValue)]? {
        guard case let .object(members) = self else { return nil }
        return members
    }

    public func objectValue(for key: String) -> AuthCanonicalJSONValue? {
        objectMembers?.first { $0.0 == key }?.1
    }

    public var canonicalData: Data {
        var output = [UInt8]()
        appendCanonical(to: &output)
        return Data(output)
    }

    private func appendCanonical(to output: inout [UInt8]) {
        switch self {
        case let .object(members):
            output.append(0x7B)
            for (index, member) in members.sorted(by: { $0.0 < $1.0 }).enumerated() {
                if index > 0 {
                    output.append(0x2C)
                }
                appendString(member.0, to: &output)
                output.append(0x3A)
                member.1.appendCanonical(to: &output)
            }
            output.append(0x7D)
        case let .array(values):
            output.append(0x5B)
            for (index, value) in values.enumerated() {
                if index > 0 {
                    output.append(0x2C)
                }
                value.appendCanonical(to: &output)
            }
            output.append(0x5D)
        case let .string(value):
            appendString(value, to: &output)
        case let .number(negative, magnitude):
            if negative {
                output.append(0x2D)
            }
            output.append(contentsOf: String(magnitude).utf8)
        case let .boolean(value):
            output.append(contentsOf: (value ? "true" : "false").utf8)
        case .null:
            output.append(contentsOf: "null".utf8)
        }
    }

    private func appendString(_ value: String, to output: inout [UInt8]) {
        output.append(0x22)
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: output.append(contentsOf: [0x5C, 0x62])
            case 0x09: output.append(contentsOf: [0x5C, 0x74])
            case 0x0A: output.append(contentsOf: [0x5C, 0x6E])
            case 0x0C: output.append(contentsOf: [0x5C, 0x66])
            case 0x0D: output.append(contentsOf: [0x5C, 0x72])
            case 0x22: output.append(contentsOf: [0x5C, 0x22])
            case 0x5C: output.append(contentsOf: [0x5C, 0x5C])
            case 0 ..< 0x20:
                output.append(contentsOf: Array(String(format: "\\u%04x", scalar.value).utf8))
            default:
                output.append(contentsOf: String(scalar).utf8)
            }
        }
        output.append(0x22)
    }
}

/// Strict RFC 8785/I-JSON validation for auth responses. Foundation's JSON
/// deserializer is intentionally not used: it accepts duplicate members and
/// silently discards one of them.
public enum AuthCanonicalJSON {
    public static func parse(_ data: Data) throws -> AuthCanonicalJSONValue {
        guard String(data: data, encoding: .utf8) != nil else { throw AuthCanonicalJSONError.invalidUTF8 }
        let bytes = Array(data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            throw AuthCanonicalJSONError.byteOrderMark
        }
        var parser = Parser(bytes: bytes)
        let value = try parser.parseDocument()
        guard value.canonicalData == data else { throw AuthCanonicalJSONError.nonCanonical }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func parseDocument() throws -> AuthCanonicalJSONValue {
            guard !bytes.isEmpty else { throw AuthCanonicalJSONError.invalidSyntax }
            let value = try parseValue()
            guard index == bytes.count else { throw AuthCanonicalJSONError.invalidSyntax }
            return value
        }

        mutating func parseValue() throws -> AuthCanonicalJSONValue {
            guard let byte = peek else { throw AuthCanonicalJSONError.invalidSyntax }
            switch byte {
            case 0x7B: return try parseObject()
            case 0x5B: return try parseArray()
            case 0x22: return try .string(parseString())
            case 0x74: try consumeLiteral("true"); return .boolean(true)
            case 0x66: try consumeLiteral("false"); return .boolean(false)
            case 0x6E: try consumeLiteral("null"); return .null
            case 0x2D, 0x30 ... 0x39: return try parseNumber()
            default: throw AuthCanonicalJSONError.invalidSyntax
            }
        }

        mutating func parseObject() throws -> AuthCanonicalJSONValue {
            try consume(0x7B)
            if consumeIfPresent(0x7D) {
                return .object([])
            }
            var members: [(String, AuthCanonicalJSONValue)] = []
            var keys = Set<String>()
            while true {
                guard peek == 0x22 else { throw AuthCanonicalJSONError.invalidSyntax }
                let key = try parseString()
                guard keys.insert(key).inserted else { throw AuthCanonicalJSONError.duplicateKey }
                try consume(0x3A)
                try members.append((key, parseValue()))
                if consumeIfPresent(0x7D) {
                    return .object(members)
                }
                try consume(0x2C)
                guard peek == 0x22 else { throw AuthCanonicalJSONError.invalidSyntax }
            }
        }

        mutating func parseArray() throws -> AuthCanonicalJSONValue {
            try consume(0x5B)
            if consumeIfPresent(0x5D) {
                return .array([])
            }
            var values: [AuthCanonicalJSONValue] = []
            while true {
                try values.append(parseValue())
                if consumeIfPresent(0x5D) {
                    return .array(values)
                }
                try consume(0x2C)
                guard peek != 0x5D else { throw AuthCanonicalJSONError.invalidSyntax }
            }
        }

        mutating func parseString() throws -> String {
            try consume(0x22)
            var utf8: [UInt8] = []
            while let byte = peek {
                index += 1
                switch byte {
                case 0x22:
                    guard let string = String(data: Data(utf8), encoding: .utf8) else { throw AuthCanonicalJSONError.invalidUnicode }
                    return string
                case 0x5C:
                    try parseEscape(into: &utf8)
                case 0 ..< 0x20:
                    throw AuthCanonicalJSONError.invalidSyntax
                case 0x80 ... 0xFF:
                    let length = utf8Length(for: byte)
                    guard length > 1, index + length - 1 <= bytes.count else { throw AuthCanonicalJSONError.invalidUnicode }
                    let sequence = [byte] + Array(bytes[index ..< index + length - 1])
                    guard String(data: Data(sequence), encoding: .utf8) != nil else { throw AuthCanonicalJSONError.invalidUnicode }
                    utf8.append(contentsOf: sequence)
                    index += length - 1
                default:
                    utf8.append(byte)
                }
            }
            throw AuthCanonicalJSONError.invalidSyntax
        }

        mutating func parseEscape(into utf8: inout [UInt8]) throws {
            guard let escaped = peek else { throw AuthCanonicalJSONError.invalidSyntax }
            index += 1
            switch escaped {
            case 0x22, 0x5C, 0x2F: utf8.append(escaped)
            case 0x62: utf8.append(0x08)
            case 0x66: utf8.append(0x0C)
            case 0x6E: utf8.append(0x0A)
            case 0x72: utf8.append(0x0D)
            case 0x74: utf8.append(0x09)
            case 0x75:
                let first = try parseHexWord()
                if (0xD800 ... 0xDBFF).contains(first) {
                    guard consumeIfPresent(0x5C), consumeIfPresent(0x75) else { throw AuthCanonicalJSONError.invalidUnicode }
                    let second = try parseHexWord()
                    guard (0xDC00 ... 0xDFFF).contains(second) else { throw AuthCanonicalJSONError.invalidUnicode }
                    let scalar = 0x10000 + ((UInt32(first) - 0xD800) << 10) + (UInt32(second) - 0xDC00)
                    guard let unicodeScalar = UnicodeScalar(scalar) else { throw AuthCanonicalJSONError.invalidUnicode }
                    utf8.append(contentsOf: String(unicodeScalar).utf8)
                } else if (0xDC00 ... 0xDFFF).contains(first) {
                    throw AuthCanonicalJSONError.invalidUnicode
                } else if let unicodeScalar = UnicodeScalar(first) {
                    utf8.append(contentsOf: String(unicodeScalar).utf8)
                } else {
                    throw AuthCanonicalJSONError.invalidUnicode
                }
            default: throw AuthCanonicalJSONError.invalidSyntax
            }
        }

        mutating func parseHexWord() throws -> UInt16 {
            guard index + 4 <= bytes.count else { throw AuthCanonicalJSONError.invalidSyntax }
            var value: UInt16 = 0
            for _ in 0 ..< 4 {
                guard let digit = hexValue(bytes[index]) else { throw AuthCanonicalJSONError.invalidSyntax }
                value = value * 16 + UInt16(digit)
                index += 1
            }
            return value
        }

        mutating func parseNumber() throws -> AuthCanonicalJSONValue {
            let start = index
            let negative = consumeIfPresent(0x2D)
            guard let first = peek else { throw AuthCanonicalJSONError.invalidSyntax }
            if first == 0x30 {
                index += 1
                if let next = peek, (0x30 ... 0x39).contains(next) {
                    throw AuthCanonicalJSONError.nonCanonical
                }
            } else {
                guard (0x31 ... 0x39).contains(first) else { throw AuthCanonicalJSONError.invalidSyntax }
                while let next = peek, (0x30 ... 0x39).contains(next) {
                    index += 1
                }
            }
            if peek == 0x2E || peek == 0x65 || peek == 0x45 {
                throw AuthCanonicalJSONError.nonCanonical
            }
            let token = String(decoding: bytes[start ..< index], as: UTF8.self)
            let magnitudeString = negative ? String(token.dropFirst()) : token
            guard let magnitude = UInt64(magnitudeString), magnitude <= 9_007_199_254_740_991 else { throw AuthCanonicalJSONError.unsafeNumber }
            if negative, magnitude == 0 {
                throw AuthCanonicalJSONError.nonCanonical
            }
            return .number(negative: negative, magnitude: magnitude)
        }

        mutating func consumeLiteral(_ literal: String) throws {
            for byte in literal.utf8 {
                try consume(byte)
            }
        }

        mutating func consume(_ expected: UInt8) throws {
            guard consumeIfPresent(expected) else { throw AuthCanonicalJSONError.invalidSyntax }
        }

        mutating func consumeIfPresent(_ expected: UInt8) -> Bool {
            guard peek == expected else { return false }
            index += 1
            return true
        }

        var peek: UInt8? {
            index < bytes.count ? bytes[index] : nil
        }

        func utf8Length(for byte: UInt8) -> Int {
            if byte < 0xE0 {
                return 2
            }
            if byte < 0xF0 {
                return 3
            }
            return 4
        }

        func hexValue(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30 ... 0x39: byte - 0x30
            case 0x41 ... 0x46: byte - 0x41 + 10
            case 0x61 ... 0x66: byte - 0x61 + 10
            default: nil
            }
        }
    }
}
