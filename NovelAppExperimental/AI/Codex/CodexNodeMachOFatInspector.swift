import Foundation

#if !FUMINIWA_ENABLE_EXPERIMENTAL_AI
#error("Codex Node executable inspection must only compile in FUMINIWAExperimental")
#endif

enum CodexNodeMachOFatInspector {
    private struct Slice {
        let architecture: CodexRuntimeArchitecture
        let cpuType: UInt32
        let cpuSubtype: UInt32
        let offset: UInt64
        let size: UInt64
    }

    private struct Layout {
        let offset: UInt64
        let size: UInt64
        let alignmentExponent: UInt32
    }

    private struct Table {
        let bytes: [UInt8]
        let sliceCount: Int
        let headerByteCount: UInt64
    }

    private struct ParseContext {
        let container: CodexNodeMachOContainer
        let byteOrder: CodexNodeMachOByteOrder
        let headerByteCount: UInt64
        let fileByteCount: UInt64
    }

    static func inspect(
        reader: CodexNodeMachOReader,
        requestedArchitecture: CodexRuntimeArchitecture,
        container: CodexNodeMachOContainer,
        byteOrder: CodexNodeMachOByteOrder,
        entryByteCount: Int
    ) throws -> CodexNodeMachOObservation {
        let table = try readTable(
            reader: reader,
            byteOrder: byteOrder,
            entryByteCount: entryByteCount
        )
        let context = ParseContext(
            container: container,
            byteOrder: byteOrder,
            headerByteCount: table.headerByteCount,
            fileByteCount: reader.byteCount
        )
        let slices = try parseSlices(
            table: table,
            entryByteCount: entryByteCount,
            context: context
        )
        try validateNonoverlappingSlices(slices)
        try validateSliceHeaders(slices, reader: reader)

        let architectures = slices.map(\.architecture)
        guard architectures.contains(requestedArchitecture) else {
            throw CodexNodeExecutableInspectionError.architectureMismatch
        }
        return CodexNodeMachOObservation(
            container: container,
            architectures: architectures.sorted { $0.rawValue < $1.rawValue }
        )
    }

    private static func readTable(
        reader: CodexNodeMachOReader,
        byteOrder: CodexNodeMachOByteOrder,
        entryByteCount: Int
    ) throws -> Table {
        let fatHeader = try reader.read(offset: 0, count: 8)
        let sliceCount = Int(CodexNodeMachOBinary.readUInt32(
            fatHeader,
            at: 4,
            byteOrder: byteOrder
        ))
        let hasBoundedSliceCount = sliceCount > 0
            && sliceCount <= CodexNodeExecutableInspectionLimits.maximumMachOSliceCount
        guard hasBoundedSliceCount else {
            throw CodexNodeExecutableInspectionError.resourceLimit
        }

        let tableByteCount = sliceCount.multipliedReportingOverflow(by: entryByteCount)
        guard !tableByteCount.overflow else {
            throw CodexNodeExecutableInspectionError.resourceLimit
        }
        let fullHeaderByteCount = 8.addingReportingOverflow(tableByteCount.partialValue)
        let headerIsWithinFile = !fullHeaderByteCount.overflow
            && UInt64(fullHeaderByteCount.partialValue) <= reader.byteCount
        guard headerIsWithinFile else {
            throw CodexNodeExecutableInspectionError.invalidMachO
        }
        let table = try reader.read(offset: 8, count: tableByteCount.partialValue)
        return Table(
            bytes: table,
            sliceCount: sliceCount,
            headerByteCount: UInt64(fullHeaderByteCount.partialValue)
        )
    }

    private static func parseSlices(
        table: Table,
        entryByteCount: Int,
        context: ParseContext
    ) throws -> [Slice] {
        var slices: [Slice] = []
        for index in 0 ..< table.sliceCount {
            let slice = try parseSlice(
                table: table.bytes,
                start: index * entryByteCount,
                context: context
            )
            guard !slices.contains(where: { $0.architecture == slice.architecture }) else {
                throw CodexNodeExecutableInspectionError.invalidMachO
            }
            slices.append(slice)
        }
        return slices
    }

    private static func parseSlice(
        table: [UInt8],
        start: Int,
        context: ParseContext
    ) throws -> Slice {
        let cpuType = CodexNodeMachOBinary.readUInt32(
            table,
            at: start,
            byteOrder: context.byteOrder
        )
        let cpuSubtype = CodexNodeMachOBinary.readUInt32(
            table,
            at: start + 4,
            byteOrder: context.byteOrder
        )
        let architecture = try CodexNodeMachOInspector.architecture(cpuType: cpuType)
        let layout = try parseLayout(
            table: table,
            start: start,
            container: context.container,
            byteOrder: context.byteOrder
        )
        try validateSlice(
            layout,
            headerByteCount: context.headerByteCount,
            fileByteCount: context.fileByteCount
        )
        return Slice(
            architecture: architecture,
            cpuType: cpuType,
            cpuSubtype: cpuSubtype,
            offset: layout.offset,
            size: layout.size
        )
    }

    private static func parseLayout(
        table: [UInt8],
        start: Int,
        container: CodexNodeMachOContainer,
        byteOrder: CodexNodeMachOByteOrder
    ) throws -> Layout {
        if container == .fat32 {
            return Layout(
                offset: UInt64(CodexNodeMachOBinary.readUInt32(
                    table,
                    at: start + 8,
                    byteOrder: byteOrder
                )),
                size: UInt64(CodexNodeMachOBinary.readUInt32(
                    table,
                    at: start + 12,
                    byteOrder: byteOrder
                )),
                alignmentExponent: CodexNodeMachOBinary.readUInt32(
                    table,
                    at: start + 16,
                    byteOrder: byteOrder
                )
            )
        }

        let reserved = CodexNodeMachOBinary.readUInt32(
            table,
            at: start + 28,
            byteOrder: byteOrder
        )
        guard reserved == 0 else {
            throw CodexNodeExecutableInspectionError.invalidMachO
        }
        return Layout(
            offset: CodexNodeMachOBinary.readUInt64(
                table,
                at: start + 8,
                byteOrder: byteOrder
            ),
            size: CodexNodeMachOBinary.readUInt64(
                table,
                at: start + 16,
                byteOrder: byteOrder
            ),
            alignmentExponent: CodexNodeMachOBinary.readUInt32(
                table,
                at: start + 24,
                byteOrder: byteOrder
            )
        )
    }

    private static func validateSlice(
        _ layout: Layout,
        headerByteCount: UInt64,
        fileByteCount: UInt64
    ) throws {
        let startsAfterHeader = layout.offset >= headerByteCount
            && layout.size >= 32
        guard startsAfterHeader else {
            throw CodexNodeExecutableInspectionError.invalidMachO
        }
        let end = layout.offset.addingReportingOverflow(layout.size)
        guard !end.overflow, end.partialValue <= fileByteCount else {
            throw CodexNodeExecutableInspectionError.invalidMachO
        }
        guard layout.alignmentExponent < 64 else {
            throw CodexNodeExecutableInspectionError.invalidMachO
        }
        let alignment = UInt64(1) << layout.alignmentExponent
        guard layout.offset.isMultiple(of: alignment) else {
            throw CodexNodeExecutableInspectionError.invalidMachO
        }
    }

    private static func validateNonoverlappingSlices(_ slices: [Slice]) throws {
        let ordered = slices.sorted { $0.offset < $1.offset }
        for index in 1 ..< ordered.count {
            let previous = ordered[index - 1]
            let previousEnd = previous.offset.addingReportingOverflow(previous.size)
            guard !previousEnd.overflow, previousEnd.partialValue <= ordered[index].offset else {
                throw CodexNodeExecutableInspectionError.invalidMachO
            }
        }
    }

    private static func validateSliceHeaders(
        _ slices: [Slice],
        reader: CodexNodeMachOReader
    ) throws {
        for slice in slices {
            let magic = try reader.read(offset: slice.offset, count: 4)
            let detectedMagic = try CodexNodeMachOBinary.topLevelMagic(magic)
            guard case let .thin64(byteOrder) = detectedMagic else {
                throw CodexNodeExecutableInspectionError.invalidMachO
            }
            let actualArchitecture = try CodexNodeMachOInspector.inspectThinSlice(
                reader: reader,
                offset: slice.offset,
                size: slice.size,
                expectedCPUType: slice.cpuType,
                expectedCPUSubtype: slice.cpuSubtype,
                byteOrder: byteOrder
            )
            guard actualArchitecture == slice.architecture else {
                throw CodexNodeExecutableInspectionError.invalidMachO
            }
        }
    }
}
