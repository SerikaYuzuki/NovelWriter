import Foundation
@testable import FUMINIWAExperimental
import Testing

@Test("thin arm64・x86_64とbyte orderを正確に観測する")
func codexNodeInspectorObservesThinMachOArchitectures() throws {
    let arm = try inspectMachOFixture(
        syntheticThinMachO(architecture: .arm64),
        architecture: .arm64
    )
    #expect(arm.machOContainer == .thin)
    #expect(arm.containedArchitectures == [.arm64])

    let x64 = try inspectMachOFixture(
        syntheticThinMachO(architecture: .x64),
        architecture: .x64
    )
    #expect(x64.machOContainer == .thin)
    #expect(x64.containedArchitectures == [.x64])

    let bigEndian = try inspectMachOFixture(
        syntheticThinMachO(architecture: .arm64, byteOrder: .bigEndian),
        architecture: .arm64
    )
    #expect(bigEndian.containedArchitectures == [.arm64])
}

@Test("fat32・fat64の両byte orderを観測するがauthorityへ昇格しない")
func codexNodeInspectorObservesFatMachOContainers() throws {
    for container in [SyntheticFatContainer.fat32, .fat64] {
        for byteOrder in [SyntheticMachOByteOrder.bigEndian, .littleEndian] {
            let fixture = syntheticFatMachO(
                container: container,
                byteOrder: byteOrder,
                architectures: [.x64, .arm64]
            )
            let observation = try inspectMachOFixture(
                fixture,
                architecture: .arm64
            )
            #expect(observation.machOContainer == expectedContainer(container))
            #expect(observation.containedArchitectures == [.arm64, .x64])
            #expect(CodexApprovedRuntimeIdentity.ProductionCatalog.approvedPolicyCount == 0)
        }
    }
}

@Test("requested architecture不一致とunsupported CPUを拒否する")
func codexNodeInspectorRejectsArchitectureMismatch() {
    #expect(
        machOFixtureError(
            syntheticThinMachO(architecture: .arm64),
            architecture: .x64
        ) == .architectureMismatch
    )
    #expect(
        machOFixtureError(
            syntheticFatMachO(
                container: .fat32,
                byteOrder: .bigEndian,
                architectures: [.arm64]
            ),
            architecture: .x64
        ) == .architectureMismatch
    )

    var unsupported = syntheticThinMachO(architecture: .arm64)
    syntheticReplaceUInt32(
        in: &unsupported,
        at: 4,
        value: 0x0100_0012,
        byteOrder: .littleEndian
    )
    #expect(machOFixtureError(unsupported) == .unsupportedArchitecture)
}

@Test("malformed・truncated・32-bit・header不整合を拒否する")
func codexNodeInspectorRejectsMalformedMachOHeaders() {
    let valid = syntheticThinMachO(architecture: .arm64)
    let thin32 = Data([0xCE, 0xFA, 0xED, 0xFE]) + Data(repeating: 0, count: 28)
    let malformedFixtures = [
        Data([0]),
        Data(valid.prefix(31)),
        Data(repeating: 0, count: 32),
        syntheticThinMachO(architecture: .arm64, fileType: 1),
        syntheticThinMachO(architecture: .arm64, reserved: 1)
    ]
    for fixture in malformedFixtures {
        #expect(machOFixtureError(fixture) == .invalidMachO)
    }
    #expect(machOFixtureError(thin32) == .unsupportedArchitecture)
}

@Test("load command count・cmdsize・alignment・cumulative bytesを検証する")
func codexNodeInspectorValidatesMachOLoadCommands() throws {
    let first = syntheticLoadCommand(declaredByteCount: 8)
    let second = syntheticLoadCommand(declaredByteCount: 16)
    let valid = syntheticThinMachO(
        architecture: .arm64,
        loadCommandCount: 2,
        loadCommandBytes: 24,
        commands: first + second
    )
    #expect(try inspectMachOFixture(valid).containedArchitectures == [.arm64])

    let invalid = [
        thinFixture(commandSize: 0, actualBytes: 8, declaredBytes: 8),
        thinFixture(commandSize: 4, actualBytes: 8, declaredBytes: 8),
        thinFixture(commandSize: 12, actualBytes: 12, declaredBytes: 12),
        syntheticThinMachO(
            architecture: .arm64,
            loadCommandCount: 2,
            loadCommandBytes: 8,
            commands: first
        ),
        thinFixture(commandSize: 8, actualBytes: 16, declaredBytes: 16),
        thinFixture(commandSize: 16, actualBytes: 16, declaredBytes: 8)
    ]
    for fixture in invalid {
        #expect(machOFixtureError(fixture) == .invalidMachO)
    }

    let excessiveCommands = syntheticThinMachO(
        architecture: .arm64,
        loadCommandCount: UInt32(
            CodexNodeExecutableInspectionLimits.maximumMachOLoadCommandCount + 1
        )
    )
    #expect(machOFixtureError(excessiveCommands) == .resourceLimit)
}

@Test("fat table count・offset overflow・alignment・overlapを拒否する")
func codexNodeInspectorValidatesFatTableBounds() {
    var exactCountHeader = Data([0xCA, 0xFE, 0xBA, 0xBE])
    exactCountHeader.append(contentsOf: [0, 0, 0, 64])
    #expect(machOFixtureError(exactCountHeader) == .invalidMachO)

    var excessiveCountHeader = Data([0xCA, 0xFE, 0xBA, 0xBE])
    excessiveCountHeader.append(contentsOf: [0, 0, 0, 65])
    #expect(machOFixtureError(excessiveCountHeader) == .resourceLimit)

    var overflow = syntheticFatMachO(
        container: .fat64,
        byteOrder: .bigEndian,
        architectures: [.arm64]
    )
    syntheticReplaceUInt64(
        in: &overflow,
        at: syntheticFatTableEntryOffset(0, container: .fat64) + 8,
        value: UInt64.max - 15,
        byteOrder: .bigEndian
    )
    #expect(machOFixtureError(overflow) == .invalidMachO)

    var unaligned = syntheticFatMachO(
        container: .fat32,
        byteOrder: .bigEndian,
        architectures: [.arm64]
    )
    syntheticReplaceUInt32(
        in: &unaligned,
        at: syntheticFatTableEntryOffset(0, container: .fat32) + 8,
        value: 33,
        byteOrder: .bigEndian
    )
    unaligned.append(0)
    #expect(machOFixtureError(unaligned) == .invalidMachO)

    var overlapping = syntheticFatMachO(
        container: .fat32,
        byteOrder: .bigEndian,
        architectures: [.arm64, .x64]
    )
    syntheticReplaceUInt32(
        in: &overlapping,
        at: syntheticFatTableEntryOffset(1, container: .fat32) + 8,
        value: 64,
        byteOrder: .bigEndian
    )
    #expect(machOFixtureError(overlapping) == .invalidMachO)
}

@Test("fat duplicate・reserved・CPU subtype/slice不一致を拒否する")
func codexNodeInspectorValidatesFatSliceIdentity() {
    var duplicate = syntheticFatMachO(
        container: .fat32,
        byteOrder: .littleEndian,
        architectures: [.arm64, .x64]
    )
    let secondEntry = syntheticFatTableEntryOffset(1, container: .fat32)
    let arm = syntheticMachOArchitecture(.arm64)
    syntheticReplaceUInt32(
        in: &duplicate,
        at: secondEntry,
        value: arm.cpuType,
        byteOrder: .littleEndian
    )
    syntheticReplaceUInt32(
        in: &duplicate,
        at: secondEntry + 4,
        value: arm.cpuSubtype,
        byteOrder: .littleEndian
    )
    #expect(machOFixtureError(duplicate) == .invalidMachO)

    var reserved = syntheticFatMachO(
        container: .fat64,
        byteOrder: .bigEndian,
        architectures: [.arm64]
    )
    syntheticReplaceUInt32(
        in: &reserved,
        at: syntheticFatTableEntryOffset(0, container: .fat64) + 28,
        value: 1,
        byteOrder: .bigEndian
    )
    #expect(machOFixtureError(reserved) == .invalidMachO)

    var subtypeMismatch = syntheticFatMachO(
        container: .fat32,
        byteOrder: .bigEndian,
        architectures: [.arm64]
    )
    syntheticReplaceUInt32(
        in: &subtypeMismatch,
        at: syntheticFatTableEntryOffset(0, container: .fat32) + 4,
        value: 1,
        byteOrder: .bigEndian
    )
    #expect(machOFixtureError(subtypeMismatch) == .invalidMachO)
}

private func inspectMachOFixture(
    _ fixture: Data,
    architecture: CodexRuntimeArchitecture = .arm64
) throws -> CodexNodeExecutableObservation {
    let root = try makeNodeInspectorTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try writeSyntheticNodeExecutable(root: root, contents: fixture)
    return try inspectSyntheticNodeExecutable(
        at: executable,
        architecture: architecture
    )
}

private func machOFixtureError(
    _ fixture: Data,
    architecture: CodexRuntimeArchitecture = .arm64
) -> CodexNodeExecutableInspectionError? {
    capturedNodeInspectionError {
        _ = try inspectMachOFixture(fixture, architecture: architecture)
    }
}

private func thinFixture(
    commandSize: UInt32,
    actualBytes: Int,
    declaredBytes: UInt32
) -> Data {
    syntheticThinMachO(
        architecture: .arm64,
        loadCommandCount: 1,
        loadCommandBytes: declaredBytes,
        commands: syntheticLoadCommand(
            declaredByteCount: commandSize,
            actualByteCount: actualBytes
        )
    )
}

private func expectedContainer(
    _ container: SyntheticFatContainer
) -> CodexNodeMachOContainer {
    switch container {
    case .fat32:
        .fat32
    case .fat64:
        .fat64
    }
}
