import Foundation

/// `JSONSerialization`が失うduplicate member等をdecode前に検査する小さいJSON scanner。
struct AIStrictJSONScanner {
    enum ValidationError: Error {
        case invalidJSON
    }

    static let maximumContainerDepth = 64

    private let bytes: [UInt8]
    private var index = 0

    init(_ source: String) {
        bytes = Array(source.utf8)
    }

    mutating func validate() throws {
        skipWhitespace()
        try parseValue(containerDepth: 0)
        skipWhitespace()
        guard index == bytes.count else {
            throw ValidationError.invalidJSON
        }
    }

    // JSON value dispatch is intentionally exhaustive at this trust boundary.
    // swiftlint:disable:next cyclomatic_complexity
    private mutating func parseValue(containerDepth: Int) throws {
        guard let byte = currentByte else {
            throw ValidationError.invalidJSON
        }

        switch byte {
        case 0x7B:
            guard containerDepth < Self.maximumContainerDepth else {
                throw ValidationError.invalidJSON
            }
            try parseObject(containerDepth: containerDepth + 1)
        case 0x5B:
            guard containerDepth < Self.maximumContainerDepth else {
                throw ValidationError.invalidJSON
            }
            try parseArray(containerDepth: containerDepth + 1)
        case 0x22:
            _ = try parseStringBytes()
        case 0x74:
            try parseLiteral([0x74, 0x72, 0x75, 0x65])
        case 0x66:
            try parseLiteral([0x66, 0x61, 0x6C, 0x73, 0x65])
        case 0x6E:
            try parseLiteral([0x6E, 0x75, 0x6C, 0x6C])
        case 0x2D, 0x30 ... 0x39:
            try parseNumber()
        default:
            throw ValidationError.invalidJSON
        }
    }

    private mutating func parseObject(containerDepth: Int) throws {
        try consume(0x7B)
        skipWhitespace()
        if consumeIfPresent(0x7D) {
            return
        }

        var memberNames: Set<Data> = []
        while true {
            let memberName = try Data(parseStringBytes())
            guard memberNames.insert(memberName).inserted else {
                throw ValidationError.invalidJSON
            }
            skipWhitespace()
            try consume(0x3A)
            skipWhitespace()
            try parseValue(containerDepth: containerDepth)
            skipWhitespace()
            if consumeIfPresent(0x7D) {
                return
            }
            try consume(0x2C)
            skipWhitespace()
        }
    }

    private mutating func parseArray(containerDepth: Int) throws {
        try consume(0x5B)
        skipWhitespace()
        if consumeIfPresent(0x5D) {
            return
        }

        while true {
            try parseValue(containerDepth: containerDepth)
            skipWhitespace()
            if consumeIfPresent(0x5D) {
                return
            }
            try consume(0x2C)
            skipWhitespace()
        }
    }

    /// JSON escapeを解決したUTF-8 byte列を返し、member名はcanonical equivalenceでなく
    /// JSON上のUnicode scalar列そのものとして比較する。
    private mutating func parseStringBytes() throws -> [UInt8] {
        try consume(0x22)
        var decoded: [UInt8] = []

        while let byte = currentByte {
            switch byte {
            case 0x22:
                index += 1
                return decoded
            case 0x5C:
                index += 1
                try parseEscape(into: &decoded)
            case 0x00 ... 0x1F:
                throw ValidationError.invalidJSON
            default:
                decoded.append(byte)
                index += 1
            }
        }
        throw ValidationError.invalidJSON
    }

    private mutating func parseEscape(into decoded: inout [UInt8]) throws {
        guard let escaped = currentByte else {
            throw ValidationError.invalidJSON
        }
        index += 1

        switch escaped {
        case 0x22, 0x2F, 0x5C:
            decoded.append(escaped)
        case 0x62:
            decoded.append(0x08)
        case 0x66:
            decoded.append(0x0C)
        case 0x6E:
            decoded.append(0x0A)
        case 0x72:
            decoded.append(0x0D)
        case 0x74:
            decoded.append(0x09)
        case 0x75:
            try parseUnicodeEscape(into: &decoded)
        default:
            throw ValidationError.invalidJSON
        }
    }

    private mutating func parseUnicodeEscape(into decoded: inout [UInt8]) throws {
        let leading = try parseUnicodeCodeUnit()
        let scalarValue: UInt32

        if (0xD800 ... 0xDBFF).contains(leading) {
            guard consumeIfPresent(0x5C), consumeIfPresent(0x75) else {
                throw ValidationError.invalidJSON
            }
            let trailing = try parseUnicodeCodeUnit()
            guard (0xDC00 ... 0xDFFF).contains(trailing) else {
                throw ValidationError.invalidJSON
            }
            scalarValue = 0x10000
                + (UInt32(leading - 0xD800) << 10)
                + UInt32(trailing - 0xDC00)
        } else {
            guard !(0xDC00 ... 0xDFFF).contains(leading) else {
                throw ValidationError.invalidJSON
            }
            scalarValue = UInt32(leading)
        }

        guard let scalar = UnicodeScalar(scalarValue) else {
            throw ValidationError.invalidJSON
        }
        decoded.append(contentsOf: String(scalar).utf8)
    }

    private mutating func parseUnicodeCodeUnit() throws -> UInt16 {
        var value: UInt16 = 0
        for _ in 0 ..< 4 {
            guard let byte = currentByte, let digit = Self.hexadecimalValue(byte) else {
                throw ValidationError.invalidJSON
            }
            value = value * 16 + UInt16(digit)
            index += 1
        }
        return value
    }

    private mutating func parseNumber() throws {
        _ = consumeIfPresent(0x2D)
        if consumeIfPresent(0x30) {
            guard currentByte.map(Self.isDigit) != true else {
                throw ValidationError.invalidJSON
            }
        } else {
            guard let byte = currentByte, (0x31 ... 0x39).contains(byte) else {
                throw ValidationError.invalidJSON
            }
            index += 1
            consumeDigits()
        }

        if consumeIfPresent(0x2E) {
            guard currentByte.map(Self.isDigit) == true else {
                throw ValidationError.invalidJSON
            }
            consumeDigits()
        }

        if currentByte == 0x65 || currentByte == 0x45 {
            index += 1
            if currentByte == 0x2B || currentByte == 0x2D {
                index += 1
            }
            guard currentByte.map(Self.isDigit) == true else {
                throw ValidationError.invalidJSON
            }
            consumeDigits()
        }
    }

    private mutating func parseLiteral(_ literal: [UInt8]) throws {
        for byte in literal {
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
            throw ValidationError.invalidJSON
        }
    }

    private mutating func consumeIfPresent(_ byte: UInt8) -> Bool {
        guard currentByte == byte else {
            return false
        }
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
