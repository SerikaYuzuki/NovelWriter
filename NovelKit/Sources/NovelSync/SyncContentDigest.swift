import Foundation

public enum SyncContentDigestError: Error, Equatable, Sendable {
    case invalidEncoding
    case invalidLength
    case invalidCharacter
}

/// UTF-8本文のSHA-256。clockやOSのファイル属性を本文同一性へ使わない。
public struct SyncContentDigest: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(content: String) {
        rawValue = SHA256.hexDigest(Array(content.utf8))
    }

    public init(validating rawValue: String) throws {
        guard rawValue.utf8.count == 64 else {
            throw SyncContentDigestError.invalidLength
        }
        guard rawValue.utf8.allSatisfy({ byte in
            (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
        }) else {
            throw SyncContentDigestError.invalidCharacter
        }
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        do {
            try self.init(validating: value)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "contentDigest must be 64 lowercase hexadecimal characters"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

private enum SHA256 {
    private static let initialHash: [UInt32] = [
        0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A,
        0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19
    ]

    private static let roundConstants: [UInt32] = [
        0x428A_2F98, 0x7137_4491, 0xB5C0_FBCF, 0xE9B5_DBA5,
        0x3956_C25B, 0x59F1_11F1, 0x923F_82A4, 0xAB1C_5ED5,
        0xD807_AA98, 0x1283_5B01, 0x2431_85BE, 0x550C_7DC3,
        0x72BE_5D74, 0x80DE_B1FE, 0x9BDC_06A7, 0xC19B_F174,
        0xE49B_69C1, 0xEFBE_4786, 0x0FC1_9DC6, 0x240C_A1CC,
        0x2DE9_2C6F, 0x4A74_84AA, 0x5CB0_A9DC, 0x76F9_88DA,
        0x983E_5152, 0xA831_C66D, 0xB003_27C8, 0xBF59_7FC7,
        0xC6E0_0BF3, 0xD5A7_9147, 0x06CA_6351, 0x1429_2967,
        0x27B7_0A85, 0x2E1B_2138, 0x4D2C_6DFC, 0x5338_0D13,
        0x650A_7354, 0x766A_0ABB, 0x81C2_C92E, 0x9272_2C85,
        0xA2BF_E8A1, 0xA81A_664B, 0xC24B_8B70, 0xC76C_51A3,
        0xD192_E819, 0xD699_0624, 0xF40E_3585, 0x106A_A070,
        0x19A4_C116, 0x1E37_6C08, 0x2748_774C, 0x34B0_BCB5,
        0x391C_0CB3, 0x4ED8_AA4A, 0x5B9C_CA4F, 0x682E_6FF3,
        0x748F_82EE, 0x78A5_636F, 0x84C8_7814, 0x8CC7_0208,
        0x90BE_FFFA, 0xA450_6CEB, 0xBEF9_A3F7, 0xC671_78F2
    ]

    static func hexDigest(_ input: [UInt8]) -> String {
        var message = input
        let bitLength = UInt64(message.count) &* 8
        message.append(0x80)
        while message.count % 64 != 56 {
            message.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }

        var hash = initialHash
        for offset in stride(from: 0, to: message.count, by: 64) {
            process(block: Array(message[offset ..< offset + 64]), hash: &hash)
        }

        return hash.map { String(format: "%08x", $0) }.joined()
    }

    private static func process(block: [UInt8], hash: inout [UInt32]) {
        let words = messageSchedule(for: block)

        var workingZero = hash[0]
        var workingOne = hash[1]
        var workingTwo = hash[2]
        var workingThree = hash[3]
        var workingFour = hash[4]
        var workingFive = hash[5]
        var workingSix = hash[6]
        var workingSeven = hash[7]

        for index in 0 ..< 64 {
            let upperSigmaOne = rotateRight(workingFour, by: 6)
                ^ rotateRight(workingFour, by: 11)
                ^ rotateRight(workingFour, by: 25)
            let choose = (workingFour & workingFive) ^ (~workingFour & workingSix)
            let temporaryOne = workingSeven
                &+ upperSigmaOne
                &+ choose
                &+ roundConstants[index]
                &+ words[index]
            let upperSigmaZero = rotateRight(workingZero, by: 2)
                ^ rotateRight(workingZero, by: 13)
                ^ rotateRight(workingZero, by: 22)
            let majority = (workingZero & workingOne)
                ^ (workingZero & workingTwo)
                ^ (workingOne & workingTwo)
            let temporaryTwo = upperSigmaZero &+ majority

            workingSeven = workingSix
            workingSix = workingFive
            workingFive = workingFour
            workingFour = workingThree &+ temporaryOne
            workingThree = workingTwo
            workingTwo = workingOne
            workingOne = workingZero
            workingZero = temporaryOne &+ temporaryTwo
        }

        hash[0] &+= workingZero
        hash[1] &+= workingOne
        hash[2] &+= workingTwo
        hash[3] &+= workingThree
        hash[4] &+= workingFour
        hash[5] &+= workingFive
        hash[6] &+= workingSix
        hash[7] &+= workingSeven
    }

    private static func messageSchedule(for block: [UInt8]) -> [UInt32] {
        var words = Array(repeating: UInt32(0), count: 64)
        for index in 0 ..< 16 {
            let base = index * 4
            words[index] = UInt32(block[base]) << 24
                | UInt32(block[base + 1]) << 16
                | UInt32(block[base + 2]) << 8
                | UInt32(block[base + 3])
        }
        for index in 16 ..< 64 {
            let first = rotateRight(words[index - 15], by: 7)
                ^ rotateRight(words[index - 15], by: 18)
                ^ (words[index - 15] >> 3)
            let second = rotateRight(words[index - 2], by: 17)
                ^ rotateRight(words[index - 2], by: 19)
                ^ (words[index - 2] >> 10)
            words[index] = words[index - 16] &+ first &+ words[index - 7] &+ second
        }
        return words
    }

    private static func rotateRight(_ value: UInt32, by amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }
}
