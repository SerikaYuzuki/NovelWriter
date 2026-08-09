import Darwin
import Foundation

#if !FUMINIWA_ENABLE_EXPERIMENTAL_AI
#error("Codex Node executable inspection must only compile in FUMINIWAExperimental")
#endif

struct CodexNodeMachOObservation {
    let container: CodexNodeMachOContainer
    let architectures: [CodexRuntimeArchitecture]
}

enum CodexNodeMachOInspector {
    private static let cpuTypeX8664: UInt32 = 0x0100_0007
    private static let cpuTypeARM64: UInt32 = 0x0100_000C
    private static let machOExecuteFileType: UInt32 = 0x0000_0002
    private static let machO64HeaderBytes = 32

    private struct ThinHeader {
        let cpuType: UInt32
        let cpuSubtype: UInt32
        let loadCommandCount: UInt64
        let loadCommandBytes: UInt64
    }

    static func inspect(
        descriptor: Int32,
        byteCount: UInt64,
        requestedArchitecture: CodexRuntimeArchitecture
    ) throws -> CodexNodeMachOObservation {
        let reader = CodexNodeMachOReader(descriptor: descriptor, byteCount: byteCount)
        let magicBytes = try reader.read(offset: 0, count: 4)
        switch try CodexNodeMachOBinary.topLevelMagic(magicBytes) {
        case let .thin64(byteOrder):
            let architecture = try inspectThinSlice(
                reader: reader,
                offset: 0,
                size: byteCount,
                expectedCPUType: nil,
                byteOrder: byteOrder
            )
            guard architecture == requestedArchitecture else {
                throw CodexNodeExecutableInspectionError.architectureMismatch
            }
            return CodexNodeMachOObservation(
                container: .thin,
                architectures: [architecture]
            )
        case .thin32:
            throw CodexNodeExecutableInspectionError.unsupportedArchitecture
        case let .fat32(byteOrder):
            return try CodexNodeMachOFatInspector.inspect(
                reader: reader,
                requestedArchitecture: requestedArchitecture,
                container: .fat32,
                byteOrder: byteOrder,
                entryByteCount: 20
            )
        case let .fat64(byteOrder):
            return try CodexNodeMachOFatInspector.inspect(
                reader: reader,
                requestedArchitecture: requestedArchitecture,
                container: .fat64,
                byteOrder: byteOrder,
                entryByteCount: 32
            )
        }
    }

    static func inspectThinSlice(
        reader: CodexNodeMachOReader,
        offset: UInt64,
        size: UInt64,
        expectedCPUType: UInt32?,
        expectedCPUSubtype: UInt32? = nil,
        byteOrder: CodexNodeMachOByteOrder
    ) throws -> CodexRuntimeArchitecture {
        guard size >= UInt64(machO64HeaderBytes) else {
            throw CodexNodeExecutableInspectionError.invalidMachO
        }
        let header = try reader.read(offset: offset, count: machO64HeaderBytes)
        let magic = try CodexNodeMachOBinary.topLevelMagic(
            Array(header.prefix(4))
        )
        guard case let .thin64(detectedOrder) = magic else {
            throw CodexNodeExecutableInspectionError.invalidMachO
        }
        guard detectedOrder == byteOrder else {
            throw CodexNodeExecutableInspectionError.invalidMachO
        }
        let identity = try parseThinHeader(
            header,
            byteOrder: byteOrder,
            sliceSize: size
        )
        if let expectedCPUType, identity.cpuType != expectedCPUType {
            throw CodexNodeExecutableInspectionError.invalidMachO
        }
        if let expectedCPUSubtype, identity.cpuSubtype != expectedCPUSubtype {
            throw CodexNodeExecutableInspectionError.invalidMachO
        }
        let architecture = try architecture(cpuType: identity.cpuType)
        try validateLoadCommands(
            reader: reader,
            sliceOffset: offset,
            loadCommandCount: identity.loadCommandCount,
            loadCommandBytes: identity.loadCommandBytes,
            byteOrder: byteOrder
        )
        return architecture
    }

    private static func parseThinHeader(
        _ header: [UInt8],
        byteOrder: CodexNodeMachOByteOrder,
        sliceSize: UInt64
    ) throws -> ThinHeader {
        let cpuType = CodexNodeMachOBinary.readUInt32(header, at: 4, byteOrder: byteOrder)
        let cpuSubtype = CodexNodeMachOBinary.readUInt32(header, at: 8, byteOrder: byteOrder)
        guard CodexNodeMachOBinary.readUInt32(
            header,
            at: 12,
            byteOrder: byteOrder
        ) == machOExecuteFileType else {
            throw CodexNodeExecutableInspectionError.invalidMachO
        }
        let loadCommandCount = UInt64(CodexNodeMachOBinary.readUInt32(
            header,
            at: 16,
            byteOrder: byteOrder
        ))
        guard loadCommandCount <= UInt64(
            CodexNodeExecutableInspectionLimits.maximumMachOLoadCommandCount
        ) else {
            throw CodexNodeExecutableInspectionError.resourceLimit
        }
        let loadCommandBytes = UInt64(CodexNodeMachOBinary.readUInt32(
            header,
            at: 20,
            byteOrder: byteOrder
        ))
        guard loadCommandBytes <= sliceSize - UInt64(machO64HeaderBytes) else {
            throw CodexNodeExecutableInspectionError.invalidMachO
        }
        guard CodexNodeMachOBinary.readUInt32(
            header,
            at: 28,
            byteOrder: byteOrder
        ) == 0 else {
            throw CodexNodeExecutableInspectionError.invalidMachO
        }
        return ThinHeader(
            cpuType: cpuType,
            cpuSubtype: cpuSubtype,
            loadCommandCount: loadCommandCount,
            loadCommandBytes: loadCommandBytes
        )
    }

    private static func validateLoadCommands(
        reader: CodexNodeMachOReader,
        sliceOffset: UInt64,
        loadCommandCount: UInt64,
        loadCommandBytes: UInt64,
        byteOrder: CodexNodeMachOByteOrder
    ) throws {
        guard loadCommandCount <= loadCommandBytes / 8 else {
            throw CodexNodeExecutableInspectionError.invalidMachO
        }
        let commandsOffset = sliceOffset.addingReportingOverflow(UInt64(machO64HeaderBytes))
        guard !commandsOffset.overflow else {
            throw CodexNodeExecutableInspectionError.invalidMachO
        }

        var consumed: UInt64 = 0
        for _ in 0 ..< loadCommandCount {
            let headerEnd = consumed.addingReportingOverflow(8)
            guard !headerEnd.overflow, headerEnd.partialValue <= loadCommandBytes else {
                throw CodexNodeExecutableInspectionError.invalidMachO
            }
            let commandOffset = commandsOffset.partialValue.addingReportingOverflow(consumed)
            guard !commandOffset.overflow else {
                throw CodexNodeExecutableInspectionError.invalidMachO
            }
            let commandHeader = try reader.read(offset: commandOffset.partialValue, count: 8)
            let commandSize = UInt64(
                CodexNodeMachOBinary.readUInt32(
                    commandHeader,
                    at: 4,
                    byteOrder: byteOrder
                )
            )
            guard commandSize >= 8, commandSize.isMultiple(of: 8) else {
                throw CodexNodeExecutableInspectionError.invalidMachO
            }
            let next = consumed.addingReportingOverflow(commandSize)
            guard !next.overflow, next.partialValue <= loadCommandBytes else {
                throw CodexNodeExecutableInspectionError.invalidMachO
            }
            consumed = next.partialValue
        }
        guard consumed == loadCommandBytes else {
            throw CodexNodeExecutableInspectionError.invalidMachO
        }
    }

    static func architecture(cpuType: UInt32) throws -> CodexRuntimeArchitecture {
        switch cpuType {
        case cpuTypeARM64:
            .arm64
        case cpuTypeX8664:
            .x64
        default:
            throw CodexNodeExecutableInspectionError.unsupportedArchitecture
        }
    }
}
