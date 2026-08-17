import Foundation

struct CanonicalJSONParser {
    private let bytes: [UInt8]
    private let maxDepth: Int
    private var index = 0

    init(
        _ data: Data,
        maxBytes: Int = SnapshotSyncV2Limits.maxCommandBytes,
        maxDepth: Int = SnapshotSyncV2Limits.maxCanonicalJSONDepth
    ) throws {
        guard data.count <= maxBytes else {
            throw CanonicalJSONError.inputTooLarge
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw CanonicalJSONError.invalidUTF8
        }
        bytes = Array(data)
        self.maxDepth = maxDepth
    }

    mutating func parse() throws -> CanonicalJSON.Value {
        skipWhitespace()
        let result = try parseValue(depth: 0)
        skipWhitespace()
        guard index == bytes.count else {
            throw CanonicalJSONError.malformed
        }
        return result
    }

    private mutating func parseValue(depth: Int) throws -> CanonicalJSON.Value {
        guard depth <= maxDepth else {
            throw CanonicalJSONError.nestingTooDeep
        }
        guard let byte = peek else {
            throw CanonicalJSONError.malformed
        }
        switch byte {
        case 123:
            return try parseObject(depth: depth)
        case 91:
            return try parseArray(depth: depth)
        case 34:
            return try .string(parseString())
        case 45, 48 ... 57:
            return try parseNumber()
        case 116:
            try consume("true")
            return .bool(true)
        case 102:
            try consume("false")
            return .bool(false)
        case 110:
            try consume("null")
            return .null
        default:
            throw CanonicalJSONError.malformed
        }
    }

    private mutating func parseObject(depth: Int) throws -> CanonicalJSON.Value {
        try expect(123)
        skipWhitespace()
        var pairs: [(String, CanonicalJSON.Value)] = []
        var keys = Set<String>()
        if peek == 125 {
            index += 1
            return .object(pairs)
        }
        while true {
            skipWhitespace()
            guard peek == 34 else {
                throw CanonicalJSONError.malformed
            }
            let key = try parseString()
            guard keys.insert(key).inserted else {
                throw CanonicalJSONError.duplicateKey(key)
            }
            skipWhitespace()
            try expect(58)
            skipWhitespace()
            try pairs.append((key, parseValue(depth: depth + 1)))
            skipWhitespace()
            if peek == 125 {
                index += 1
                return .object(pairs)
            }
            try expect(44)
        }
    }

    private mutating func parseArray(depth: Int) throws -> CanonicalJSON.Value {
        try expect(91)
        skipWhitespace()
        var values: [CanonicalJSON.Value] = []
        if peek == 93 {
            index += 1
            return .array(values)
        }
        while true {
            try values.append(parseValue(depth: depth + 1))
            skipWhitespace()
            if peek == 93 {
                index += 1
                return .array(values)
            }
            try expect(44)
            skipWhitespace()
        }
    }

    private mutating func parseString() throws -> String {
        try expect(34)
        var scalars: [UnicodeScalar] = []
        while let byte = peek {
            index += 1
            if byte == 34 {
                return String(String.UnicodeScalarView(scalars))
            }
            if byte == 92 {
                try appendEscapedScalar(to: &scalars)
            } else {
                try appendLiteralChunk(startingAt: index - 1, to: &scalars)
            }
        }
        throw CanonicalJSONError.malformed
    }

    private mutating func appendEscapedScalar(
        to scalars: inout [UnicodeScalar]
    ) throws {
        guard let escape = peek else {
            throw CanonicalJSONError.malformed
        }
        index += 1
        if escape == 117 {
            let scalar = try parseUnicodeEscape()
            guard !(0xD800 ... 0xDFFF).contains(scalar.value) else {
                throw CanonicalJSONError.malformed
            }
            scalars.append(scalar)
            return
        }
        try scalars.append(escapedScalar(for: escape))
    }

    private func escapedScalar(for escape: UInt8) throws -> UnicodeScalar {
        switch escape {
        case 34:
            "\""
        case 92:
            "\\"
        case 47:
            "/"
        case 98:
            "\u{8}"
        case 102:
            "\u{c}"
        case 110:
            "\n"
        case 114:
            "\r"
        case 116:
            "\t"
        default:
            throw CanonicalJSONError.malformed
        }
    }

    private mutating func appendLiteralChunk(
        startingAt start: Int,
        to scalars: inout [UnicodeScalar]
    ) throws {
        guard bytes[start] >= 0x20 else {
            throw CanonicalJSONError.malformed
        }
        while index < bytes.count,
              bytes[index] >= 0x20,
              bytes[index] != 34,
              bytes[index] != 92 {
            index += 1
        }
        guard let chunk = String(
            bytes: bytes[start ..< index],
            encoding: .utf8
        ) else {
            throw CanonicalJSONError.invalidUTF8
        }
        scalars.append(contentsOf: chunk.unicodeScalars)
    }

    private mutating func parseUnicodeEscape() throws -> UnicodeScalar {
        guard index + 4 <= bytes.count else {
            throw CanonicalJSONError.malformed
        }
        let text = String(
            bytes: bytes[index ..< (index + 4)],
            encoding: .ascii
        )
        index += 4
        guard let value = text.flatMap({ UInt32($0, radix: 16) }),
              let scalar = UnicodeScalar(value) else {
            throw CanonicalJSONError.malformed
        }
        return scalar
    }

    private mutating func parseNumber() throws -> CanonicalJSON.Value {
        let start = index
        if peek == 45 {
            index += 1
        }
        guard let first = peek else {
            throw CanonicalJSONError.malformed
        }
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
        guard let text = String(
            bytes: bytes[start ..< index],
            encoding: .ascii
        ) else {
            throw CanonicalJSONError.malformed
        }
        guard let number = Int64(text),
              number >= -9_007_199_254_740_991,
              number <= 9_007_199_254_740_991 else {
            throw CanonicalJSONError.unsafeInteger
        }
        return .number(number)
    }
}

private extension CanonicalJSONParser {
    mutating func consume(_ string: String) throws {
        let expected = Array(string.utf8)
        let end = min(index + expected.count, bytes.count)
        guard bytes[index ..< end].elementsEqual(expected) else {
            throw CanonicalJSONError.malformed
        }
        index += expected.count
    }

    mutating func expect(_ byte: UInt8) throws {
        guard peek == byte else {
            throw CanonicalJSONError.malformed
        }
        index += 1
    }

    mutating func skipWhitespace() {
        while let byte = peek,
              byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            index += 1
        }
    }

    var peek: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }
}
