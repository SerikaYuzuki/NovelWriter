import Foundation

public extension Data {
    /// RFC 4648 URL alphabet, unpadded, with zero unused low bits.
    init?(base64URL value: String) {
        var result = Data()
        result.reserveCapacity(value.utf8.count / 4 * 3)
        var bits: UInt32 = 0
        var count = 0
        for byte in value.utf8 {
            let digit: UInt32
            switch byte {
            case 65...90: digit = UInt32(byte - 65)
            case 97...122: digit = UInt32(byte - 97 + 26)
            case 48...57: digit = UInt32(byte - 48 + 52)
            case 45: digit = 62
            case 95: digit = 63
            default: return nil
            }
            bits = (bits << 6) | digit
            count += 6
            if count >= 8 {
                count -= 8
                result.append(UInt8((bits >> count) & 255))
                bits &= (1 << count) - 1
            }
        }
        guard count != 6, bits == 0 else { return nil }
        self = result
    }
}
