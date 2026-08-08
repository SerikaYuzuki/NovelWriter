import Foundation

struct CodexStrictJSONScanner {
    enum ScanError: Error {
        case malformed
        case duplicateObjectMember
    }

    private static let maximumDepth = 64

    private let bytes: [UInt8]
    private var index = 0

    init(_ source: String) {
        bytes = Array(source.utf8)
    }

    mutating func validate() throws {
        skipWhitespace()
        try parseValue(depth: 0)
        skipWhitespace()
        guard index == bytes.count else {
            throw ScanError.malformed
        }
    }

    // JSON value dispatch is intentionally exhaustive at this boundary.
    // swiftlint:disable:next cyclomatic_complexity
    private mutating func parseValue(depth: Int) throws {
        guard depth <= Self.maximumDepth, let byte = currentByte else {
            throw ScanError.malformed
        }
        switch byte {
        case 0x7B:
            guard depth < Self.maximumDepth else {
                throw ScanError.malformed
            }
            try parseObject(depth: depth + 1)
        case 0x5B:
            guard depth < Self.maximumDepth else {
                throw ScanError.malformed
            }
            try parseArray(depth: depth + 1)
        case 0x22:
            _ = try parseString()
        case 0x74:
            try parseLiteral("true")
        case 0x66:
            try parseLiteral("false")
        case 0x6E:
            try parseLiteral("null")
        case 0x2D, 0x30 ... 0x39:
            try parseNumber()
        default:
            throw ScanError.malformed
        }
    }

    private mutating func parseObject(depth: Int) throws {
        try consume(0x7B)
        skipWhitespace()
        if consumeIfPresent(0x7D) {
            return
        }

        var keys: Set<String> = []
        while true {
            let key = try parseString()
            guard keys.insert(key).inserted else {
                throw ScanError.duplicateObjectMember
            }
            skipWhitespace()
            try consume(0x3A)
            skipWhitespace()
            try parseValue(depth: depth)
            skipWhitespace()
            if consumeIfPresent(0x7D) {
                return
            }
            try consume(0x2C)
            skipWhitespace()
        }
    }

    private mutating func parseArray(depth: Int) throws {
        try consume(0x5B)
        skipWhitespace()
        if consumeIfPresent(0x5D) {
            return
        }

        while true {
            try parseValue(depth: depth)
            skipWhitespace()
            if consumeIfPresent(0x5D) {
                return
            }
            try consume(0x2C)
            skipWhitespace()
        }
    }

    private mutating func parseString() throws -> String {
        guard currentByte == 0x22 else {
            throw ScanError.malformed
        }
        let start = index
        index += 1

        while let byte = currentByte {
            switch byte {
            case 0x22:
                index += 1
                let encoded = Data(bytes[start ..< index])
                do {
                    let value = try JSONSerialization.jsonObject(
                        with: encoded,
                        options: [.fragmentsAllowed]
                    )
                    guard let string = value as? String else {
                        throw ScanError.malformed
                    }
                    return string
                } catch let error as ScanError {
                    throw error
                } catch {
                    throw ScanError.malformed
                }
            case 0x5C:
                index += 1
                try parseEscape()
            case 0x00 ... 0x1F:
                throw ScanError.malformed
            default:
                index += 1
            }
        }
        throw ScanError.malformed
    }

    private mutating func parseEscape() throws {
        guard let escaped = currentByte else {
            throw ScanError.malformed
        }
        guard escaped == 0x75 else {
            guard [0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(escaped) else {
                throw ScanError.malformed
            }
            index += 1
            return
        }

        index += 1
        let codeUnit = try parseUnicodeCodeUnit()
        if (0xD800 ... 0xDBFF).contains(codeUnit) {
            guard consumeIfPresent(0x5C), consumeIfPresent(0x75) else {
                throw ScanError.malformed
            }
            let trailing = try parseUnicodeCodeUnit()
            guard (0xDC00 ... 0xDFFF).contains(trailing) else {
                throw ScanError.malformed
            }
        } else if (0xDC00 ... 0xDFFF).contains(codeUnit) {
            throw ScanError.malformed
        }
    }

    private mutating func parseNumber() throws {
        let isNegative = consumeIfPresent(0x2D)
        if consumeIfPresent(0x30) {
            guard !isNegative else {
                throw ScanError.malformed
            }
            if currentByte.map(Self.isDigit) == true {
                throw ScanError.malformed
            }
        } else {
            guard let byte = currentByte, (0x31 ... 0x39).contains(byte) else {
                throw ScanError.malformed
            }
            index += 1
            consumeDigits()
        }

        if consumeIfPresent(0x2E) {
            guard currentByte.map(Self.isDigit) == true else {
                throw ScanError.malformed
            }
            consumeDigits()
        }
        if currentByte == 0x65 || currentByte == 0x45 {
            index += 1
            if currentByte == 0x2B || currentByte == 0x2D {
                index += 1
            }
            guard currentByte.map(Self.isDigit) == true else {
                throw ScanError.malformed
            }
            consumeDigits()
        }
    }

    private mutating func parseUnicodeCodeUnit() throws -> UInt16 {
        var value: UInt16 = 0
        for _ in 0 ..< 4 {
            guard let hexadecimal = currentByte else {
                throw ScanError.malformed
            }
            guard let digit = Self.hexadecimalValue(hexadecimal) else {
                throw ScanError.malformed
            }
            value = value * 16 + UInt16(digit)
            index += 1
        }
        return value
    }

    private mutating func parseLiteral(_ literal: StaticString) throws {
        for byte in literal.withUTF8Buffer({ Array($0) }) {
            try consume(byte)
        }
    }

    private mutating func consumeDigits() {
        while currentByte.map(Self.isDigit) == true {
            index += 1
        }
    }

    private mutating func skipWhitespace() {
        while let byte = currentByte, [0x20, 0x09, 0x0A, 0x0D].contains(byte) {
            index += 1
        }
    }

    private mutating func consume(_ byte: UInt8) throws {
        guard consumeIfPresent(byte) else {
            throw ScanError.malformed
        }
    }

    private mutating func consumeIfPresent(_ byte: UInt8) -> Bool {
        guard currentByte == byte else { return false }
        index += 1
        return true
    }

    private var currentByte: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (0x30 ... 0x39).contains(byte)
    }

    private static func hexadecimalValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30 ... 0x39:
            byte - 0x30
        case 0x41 ... 0x46:
            byte - 0x41 + 10
        case 0x61 ... 0x66:
            byte - 0x61 + 10
        default:
            nil
        }
    }
}
