import Foundation

#if !FUMINIWA_ENABLE_EXPERIMENTAL_AI
#error("Codex runtime approval must only compile in FUMINIWAExperimental")
#endif

enum CodexRuntimeApprovalCheckedArithmetic {
    static func add(_ left: UInt64, _ right: UInt64) throws -> UInt64 {
        let result = left.addingReportingOverflow(right)
        guard !result.overflow else {
            throw CodexRuntimeApprovalError.arithmeticOverflow
        }
        return result.partialValue
    }

    static func add(_ left: Int, _ right: Int) throws -> Int {
        let result = left.addingReportingOverflow(right)
        guard !result.overflow else {
            throw CodexRuntimeApprovalError.arithmeticOverflow
        }
        return result.partialValue
    }
}

enum CodexRuntimeApprovalValidation {
    static func isExactVersion(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        let isBoundedExactVersion = !bytes.isEmpty
            && bytes.count <= CodexRuntimeApprovalLimits.maximumVersionBytes
            && bytes.allSatisfy {
                isASCIIDigit($0) || isASCIIAlpha($0) || $0 == 0x2E || $0 == 0x2D
            }
        guard isBoundedExactVersion else { return false }

        let components = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = components[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3, core.allSatisfy(isCanonicalNumericIdentifier) else {
            return false
        }
        if components.count == 2 {
            let prerelease = components[1].split(separator: ".", omittingEmptySubsequences: false)
            guard !prerelease.isEmpty, prerelease.allSatisfy(isPrereleaseIdentifier) else {
                return false
            }
        }
        return true
    }

    static func isNodeVersion(_ value: String) -> Bool {
        value.first == "v" && isExactVersion(String(value.dropFirst()))
    }

    static func decodeSHA512SRI(_ value: String) -> Data? {
        let prefix = "sha512-"
        guard value.hasPrefix(prefix) else { return nil }
        let encoded = String(value.dropFirst(prefix.count))
        guard let decoded = Data(base64Encoded: encoded), decoded.count == 64 else {
            return nil
        }
        guard decoded.base64EncodedString() == encoded else { return nil }
        return decoded
    }

    static func decodeLowercaseHex(_ value: String, byteCount: Int) -> Data? {
        let bytes = Array(value.utf8)
        let expectedCount = byteCount.multipliedReportingOverflow(by: 2)
        guard !expectedCount.overflow, bytes.count == expectedCount.partialValue else {
            return nil
        }
        var decoded = Data(capacity: byteCount)
        for offset in stride(from: 0, to: bytes.count, by: 2) {
            let high = lowercaseHexNibble(bytes[offset])
            let low = lowercaseHexNibble(bytes[offset + 1])
            guard let high, let low else {
                return nil
            }
            decoded.append(high << 4 | low)
        }
        return decoded
    }

    static func requireCanonicalModuleID(_ value: String) throws {
        let bytes = Array(value.utf8)
        let isCanonical = !bytes.isEmpty
            && bytes.count <= CodexRuntimeApprovalLimits.maximumModuleIDBytes
            && bytes.first != 0x2F
            && bytes.last != 0x2F
            && bytes.allSatisfy(isModuleIDByte)
        guard isCanonical else {
            throw CodexRuntimeApprovalError.invalidModuleID
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CodexRuntimeApprovalError.invalidModuleID
        }
    }

    static func requireCanonicalRelativePath(_ value: String) throws {
        let bytes = Array(value.utf8)
        let isCanonical = !bytes.isEmpty
            && bytes.count <= CodexRuntimeApprovalLimits.maximumRelativePathBytes
            && bytes == Array(value.precomposedStringWithCanonicalMapping.utf8)
            && bytes.first != 0x2F
            && bytes.last != 0x2F
            && !bytes.contains(0)
            && !bytes.contains(0x5C)
            && bytes.allSatisfy { $0 >= 0x20 && $0 != 0x7F }
            && !containsUnicodeLineOrParagraphSeparator(bytes)
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
                    && !CharacterSet.illegalCharacters.contains($0)
                    && $0.properties.generalCategory != .format
            }
        guard isCanonical else {
            throw CodexRuntimeApprovalError.invalidPath
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ component in
            let count = component.utf8.count
            return !component.isEmpty
                && component != "."
                && component != ".."
                && count <= CodexRuntimeApprovalLimits.maximumPathComponentBytes
        }) else {
            throw CodexRuntimeApprovalError.invalidPath
        }
    }

    static func requireContent(
        _ content: CodexRuntimeArtifactContentIdentity,
        for role: CodexRuntimeInventoryRole
    ) throws {
        switch (role, content) {
        case let (.evaluatedSource, .exactFile(byteCount, digest)),
             let (.resolutionMetadata, .exactFile(byteCount, digest)),
             let (.executable, .exactFile(byteCount, digest)),
             let (.conditional, .exactFile(byteCount, digest)),
             let (.provenance, .exactFile(byteCount, digest)):
            guard byteCount <= CodexRuntimeApprovalLimits.maximumExactArtifactBytes else {
                throw CodexRuntimeApprovalError.invalidByteCount
            }
            guard decodeLowercaseHex(digest, byteCount: 32) != nil else {
                throw CodexRuntimeApprovalError.invalidDigest
            }
        case let (.requestData, .boundedRequestData(maximumByteCount)):
            let isValidByteCount = maximumByteCount > 0
                && maximumByteCount <= CodexRuntimeApprovalLimits.maximumRequestDataBytes
            guard isValidByteCount else {
                throw CodexRuntimeApprovalError.invalidByteCount
            }
        case (.operatingSystemTrust, .operatingSystemProvided),
             (.forbidden, .forbidden):
            break
        default:
            throw CodexRuntimeApprovalError.invalidArtifactContent
        }
    }

    private static func isCanonicalNumericIdentifier(_ value: Substring) -> Bool {
        guard !value.isEmpty, value.utf8.allSatisfy(isASCIIDigit) else { return false }
        return value.count == 1 || value.first != "0"
    }

    private static func isPrereleaseIdentifier(_ value: Substring) -> Bool {
        guard !value.isEmpty, value.utf8.allSatisfy({
            isASCIIDigit($0) || isASCIIAlpha($0) || $0 == 0x2D
        }) else {
            return false
        }
        return !value.utf8.allSatisfy(isASCIIDigit) || isCanonicalNumericIdentifier(value)
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        (0x30 ... 0x39).contains(byte)
    }

    private static func isASCIIAlpha(_ byte: UInt8) -> Bool {
        (0x41 ... 0x5A).contains(byte) || (0x61 ... 0x7A).contains(byte)
    }

    private static func isModuleIDByte(_ byte: UInt8) -> Bool {
        isASCIIDigit(byte)
            || isASCIIAlpha(byte)
            || [0x2F, 0x2E, 0x40, 0x5F, 0x2B, 0x2D].contains(byte)
    }

    private static func containsUnicodeLineOrParagraphSeparator(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 3 else { return false }
        return bytes.indices.dropLast(2).contains { index in
            bytes[index] == 0xE2
                && bytes[index + 1] == 0x80
                && (bytes[index + 2] == 0xA8 || bytes[index + 2] == 0xA9)
        }
    }

    private static func lowercaseHexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30 ... 0x39:
            byte - 0x30
        case 0x61 ... 0x66:
            byte - 0x61 + 10
        default:
            nil
        }
    }
}
