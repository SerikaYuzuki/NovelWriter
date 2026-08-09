import Darwin
import Foundation

#if !FUMINIWA_ENABLE_EXPERIMENTAL_AI
#error("Codex Node executable inspection must only compile in FUMINIWAExperimental")
#endif

enum CodexNodeMachOByteOrder: Equatable {
    case littleEndian
    case bigEndian
}

enum CodexNodeMachOTopLevelMagic {
    case thin64(CodexNodeMachOByteOrder)
    case thin32
    case fat32(CodexNodeMachOByteOrder)
    case fat64(CodexNodeMachOByteOrder)
}

struct CodexNodeMachOReader {
    let descriptor: Int32
    let byteCount: UInt64

    func read(offset: UInt64, count: Int) throws -> [UInt8] {
        guard count >= 0, offset <= byteCount else {
            throw CodexNodeExecutableInspectionError.invalidMachO
        }
        let requestedCount = UInt64(count)
        guard requestedCount <= byteCount - offset else {
            throw CodexNodeExecutableInspectionError.invalidMachO
        }

        var bytes = [UInt8](repeating: 0, count: count)
        var totalRead = 0
        while totalRead < count {
            let result = bytes.withUnsafeMutableBytes { rawBuffer in
                Darwin.pread(
                    descriptor,
                    rawBuffer.baseAddress?.advanced(by: totalRead),
                    count - totalRead,
                    off_t(offset + UInt64(totalRead))
                )
            }
            if result < 0, errno == EINTR {
                continue
            }
            guard result >= 0 else {
                throw CodexNodeExecutableInspectionError.readFailed
            }
            guard result > 0 else {
                throw CodexNodeExecutableInspectionError.fileChanged
            }
            totalRead += result
        }
        return bytes
    }
}

enum CodexNodeMachOBinary {
    static func topLevelMagic(_ bytes: [UInt8]) throws -> CodexNodeMachOTopLevelMagic {
        guard bytes.count == 4 else {
            throw CodexNodeExecutableInspectionError.invalidMachO
        }
        return switch bytes {
        case [0xCF, 0xFA, 0xED, 0xFE]:
            .thin64(.littleEndian)
        case [0xFE, 0xED, 0xFA, 0xCF]:
            .thin64(.bigEndian)
        case [0xCE, 0xFA, 0xED, 0xFE], [0xFE, 0xED, 0xFA, 0xCE]:
            .thin32
        case [0xCA, 0xFE, 0xBA, 0xBE]:
            .fat32(.bigEndian)
        case [0xBE, 0xBA, 0xFE, 0xCA]:
            .fat32(.littleEndian)
        case [0xCA, 0xFE, 0xBA, 0xBF]:
            .fat64(.bigEndian)
        case [0xBF, 0xBA, 0xFE, 0xCA]:
            .fat64(.littleEndian)
        default:
            throw CodexNodeExecutableInspectionError.invalidMachO
        }
    }

    static func readUInt32(
        _ bytes: [UInt8],
        at offset: Int,
        byteOrder: CodexNodeMachOByteOrder
    ) -> UInt32 {
        let values = bytes[offset ..< offset + 4].map(UInt32.init)
        switch byteOrder {
        case .bigEndian:
            return values.reduce(0) { ($0 << 8) | $1 }
        case .littleEndian:
            return values.reversed().reduce(0) { ($0 << 8) | $1 }
        }
    }

    static func readUInt64(
        _ bytes: [UInt8],
        at offset: Int,
        byteOrder: CodexNodeMachOByteOrder
    ) -> UInt64 {
        let values = bytes[offset ..< offset + 8].map(UInt64.init)
        switch byteOrder {
        case .bigEndian:
            return values.reduce(0) { ($0 << 8) | $1 }
        case .littleEndian:
            return values.reversed().reduce(0) { ($0 << 8) | $1 }
        }
    }
}
