import Foundation
@testable import FUMINIWAExperimental

enum SyntheticMachOByteOrder {
    case littleEndian
    case bigEndian
}

enum SyntheticFatContainer {
    case fat32
    case fat64

    var tableEntryByteCount: Int {
        switch self {
        case .fat32:
            20
        case .fat64:
            32
        }
    }
}

struct SyntheticMachOArchitecture {
    let cpuType: UInt32
    let cpuSubtype: UInt32
}

func syntheticMachOArchitecture(
    _ architecture: CodexRuntimeArchitecture
) -> SyntheticMachOArchitecture {
    switch architecture {
    case .arm64:
        SyntheticMachOArchitecture(cpuType: 0x0100_000C, cpuSubtype: 0)
    case .x64:
        SyntheticMachOArchitecture(cpuType: 0x0100_0007, cpuSubtype: 3)
    }
}

func syntheticThinMachO(
    architecture: CodexRuntimeArchitecture,
    byteOrder: SyntheticMachOByteOrder = .littleEndian,
    fileType: UInt32 = 2,
    loadCommandCount: UInt32? = nil,
    loadCommandBytes: UInt32? = nil,
    commands: Data = Data(),
    reserved: UInt32 = 0
) -> Data {
    let identity = syntheticMachOArchitecture(architecture)
    var data = Data(syntheticThinMagic(byteOrder))
    data.appendSyntheticUInt32(identity.cpuType, byteOrder: byteOrder)
    data.appendSyntheticUInt32(identity.cpuSubtype, byteOrder: byteOrder)
    data.appendSyntheticUInt32(fileType, byteOrder: byteOrder)
    data.appendSyntheticUInt32(loadCommandCount ?? (commands.isEmpty ? 0 : 1), byteOrder: byteOrder)
    data.appendSyntheticUInt32(loadCommandBytes ?? UInt32(commands.count), byteOrder: byteOrder)
    data.appendSyntheticUInt32(0, byteOrder: byteOrder)
    data.appendSyntheticUInt32(reserved, byteOrder: byteOrder)
    data.append(commands)
    return data
}

func syntheticLoadCommand(
    command: UInt32 = 0x1B,
    declaredByteCount: UInt32,
    actualByteCount: Int? = nil,
    byteOrder: SyntheticMachOByteOrder = .littleEndian
) -> Data {
    let count = actualByteCount ?? Int(declaredByteCount)
    var data = Data()
    data.appendSyntheticUInt32(command, byteOrder: byteOrder)
    data.appendSyntheticUInt32(declaredByteCount, byteOrder: byteOrder)
    if count > data.count {
        data.append(Data(repeating: 0xA5, count: count - data.count))
    } else if count < data.count {
        data = Data(data.prefix(count))
    }
    return data
}

func syntheticFatMachO(
    container: SyntheticFatContainer,
    byteOrder: SyntheticMachOByteOrder,
    architectures: [CodexRuntimeArchitecture]
) -> Data {
    let slices = architectures.map {
        syntheticThinMachO(architecture: $0)
    }
    let entryBytes = container.tableEntryByteCount
    let headerByteCount = 8 + (entryBytes * architectures.count)
    var offsets: [Int] = []
    var cursor = headerByteCount
    for slice in slices {
        cursor = syntheticAlignedOffset(cursor, alignment: 8)
        offsets.append(cursor)
        cursor += slice.count
    }

    var result = Data(syntheticFatMagic(container, byteOrder: byteOrder))
    result.appendSyntheticUInt32(UInt32(architectures.count), byteOrder: byteOrder)
    for (index, architecture) in architectures.enumerated() {
        let identity = syntheticMachOArchitecture(architecture)
        result.appendSyntheticUInt32(identity.cpuType, byteOrder: byteOrder)
        result.appendSyntheticUInt32(identity.cpuSubtype, byteOrder: byteOrder)
        if container == .fat32 {
            result.appendSyntheticUInt32(UInt32(offsets[index]), byteOrder: byteOrder)
            result.appendSyntheticUInt32(UInt32(slices[index].count), byteOrder: byteOrder)
        } else {
            result.appendSyntheticUInt64(UInt64(offsets[index]), byteOrder: byteOrder)
            result.appendSyntheticUInt64(UInt64(slices[index].count), byteOrder: byteOrder)
        }
        result.appendSyntheticUInt32(3, byteOrder: byteOrder)
        if container == .fat64 {
            result.appendSyntheticUInt32(0, byteOrder: byteOrder)
        }
    }
    for (index, slice) in slices.enumerated() {
        if result.count < offsets[index] {
            result.append(Data(repeating: 0, count: offsets[index] - result.count))
        }
        result.append(slice)
    }
    return result
}

func syntheticFatTableEntryOffset(
    _ index: Int,
    container: SyntheticFatContainer
) -> Int {
    8 + (index * container.tableEntryByteCount)
}

func syntheticReplaceUInt32(
    in data: inout Data,
    at offset: Int,
    value: UInt32,
    byteOrder: SyntheticMachOByteOrder
) {
    data.replaceSubrange(
        offset ..< offset + 4,
        with: syntheticBytes(value, byteOrder: byteOrder)
    )
}

func syntheticReplaceUInt64(
    in data: inout Data,
    at offset: Int,
    value: UInt64,
    byteOrder: SyntheticMachOByteOrder
) {
    data.replaceSubrange(
        offset ..< offset + 8,
        with: syntheticBytes(value, byteOrder: byteOrder)
    )
}

private func syntheticThinMagic(_ byteOrder: SyntheticMachOByteOrder) -> [UInt8] {
    switch byteOrder {
    case .littleEndian:
        [0xCF, 0xFA, 0xED, 0xFE]
    case .bigEndian:
        [0xFE, 0xED, 0xFA, 0xCF]
    }
}

private func syntheticFatMagic(
    _ container: SyntheticFatContainer,
    byteOrder: SyntheticMachOByteOrder
) -> [UInt8] {
    switch (container, byteOrder) {
    case (.fat32, .bigEndian):
        [0xCA, 0xFE, 0xBA, 0xBE]
    case (.fat32, .littleEndian):
        [0xBE, 0xBA, 0xFE, 0xCA]
    case (.fat64, .bigEndian):
        [0xCA, 0xFE, 0xBA, 0xBF]
    case (.fat64, .littleEndian):
        [0xBF, 0xBA, 0xFE, 0xCA]
    }
}

private func syntheticAlignedOffset(_ value: Int, alignment: Int) -> Int {
    ((value + alignment - 1) / alignment) * alignment
}

private func syntheticBytes(
    _ value: UInt32,
    byteOrder: SyntheticMachOByteOrder
) -> [UInt8] {
    let shifts = byteOrder == .bigEndian
        ? stride(from: 24, through: 0, by: -8)
        : stride(from: 0, through: 24, by: 8)
    return shifts.map { UInt8(truncatingIfNeeded: value >> UInt32($0)) }
}

private func syntheticBytes(
    _ value: UInt64,
    byteOrder: SyntheticMachOByteOrder
) -> [UInt8] {
    let shifts = byteOrder == .bigEndian
        ? stride(from: 56, through: 0, by: -8)
        : stride(from: 0, through: 56, by: 8)
    return shifts.map { UInt8(truncatingIfNeeded: value >> UInt64($0)) }
}

private extension Data {
    mutating func appendSyntheticUInt32(
        _ value: UInt32,
        byteOrder: SyntheticMachOByteOrder
    ) {
        append(contentsOf: syntheticBytes(value, byteOrder: byteOrder))
    }

    mutating func appendSyntheticUInt64(
        _ value: UInt64,
        byteOrder: SyntheticMachOByteOrder
    ) {
        append(contentsOf: syntheticBytes(value, byteOrder: byteOrder))
    }
}
