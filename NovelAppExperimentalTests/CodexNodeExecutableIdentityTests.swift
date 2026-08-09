import Darwin
import Foundation
@testable import FUMINIWAExperimental
import Testing

@Test("synthetic thin arm64のbytes・SHA・owner・mode・signatureを観測する")
func codexNodeInspectorObservesSyntheticIdentity() throws {
    let root = try makeNodeInspectorTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try writeSyntheticNodeExecutable(root: root)
    let invalidSignature = CodexNodeCodeSignatureObservation(
        validity: .invalid(status: -67050),
        cdHash: String(repeating: "a", count: 40),
        informationStatus: -25293
    )

    let observation = try inspectSyntheticNodeExecutable(
        at: executable,
        codeSignature: invalidSignature
    )

    #expect(observation.architecture == .arm64)
    #expect(observation.machOContainer == .thin)
    #expect(observation.containedArchitectures == [.arm64])
    #expect(observation.byteCount == 32)
    #expect(observation.sha256 == "79e4214b770ec982f202b553b1f70eaa9f1888135d7d4a341d378153fe193e6d")
    #expect(observation.ownerUserID == UInt32(geteuid()))
    #expect(observation.permissionMode == 0o700)
    #expect(observation.codeSignature == invalidSignature)
}

@Test("observationはpath・FD・capability・approval authorityを保持しない")
func codexNodeObservationHasNoExecutionOrApprovalCapability() throws {
    let root = try makeNodeInspectorTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try writeSyntheticNodeExecutable(root: root)
    let observation = try inspectSyntheticNodeExecutable(at: executable)
    let storedPropertyNames = Set(
        Mirror(reflecting: observation).children.compactMap(\.label)
    )

    #expect(storedPropertyNames == [
        "architecture",
        "byteCount",
        "codeSignature",
        "containedArchitectures",
        "machOContainer",
        "ownerUserID",
        "permissionMode",
        "sha256"
    ])
    #expect(CodexApprovedRuntimeIdentity.ProductionCatalog.approvedPolicyCount == 0)

    let proposal = try CodexRuntimeApprovalProposal(policy: makeRuntimeApprovalPolicy())
    #expect(throws: CodexRuntimeApprovalError.approvalUnavailable) {
        _ = try CodexApprovedRuntimeIdentity.ProductionCatalog.approval(matching: proposal)
    }
}

@Test("owner実行modeだけを許可し危険modeを拒否する")
func codexNodeInspectorValidatesExecutableModes() throws {
    let root = try makeNodeInspectorTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try writeSyntheticNodeExecutable(root: root)

    for mode: mode_t in [0o500, 0o700, 0o555, 0o755] {
        #expect(chmod(executable.path, mode) == 0)
        #expect(try inspectSyntheticNodeExecutable(at: executable).permissionMode == UInt16(mode))
    }

    #expect(chmod(executable.path, 0o400) == 0)
    #expect(nodeInspectionError(at: executable) == .notExecutable)

    for mode: mode_t in [0o775, 0o757, 0o4700, 0o2700, 0o1700] {
        #expect(chmod(executable.path, mode) == 0)
        #expect(nodeInspectionError(at: executable) == .invalidMode)
    }
}

@Test("executable size capを1 byte超えたfileをhash前に拒否する")
func codexNodeInspectorRejectsOversizedExecutableBeforeHashing() throws {
    let root = try makeNodeInspectorTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let oversized = root.appending(path: "node")
    try makeSparseSyntheticNodeExecutable(
        at: oversized,
        byteCount: CodexNodeExecutableInspectionLimits.maximumExecutableBytes + 1
    )
    #expect(nodeInspectionError(at: oversized) == .resourceLimit)
}

@Test("executable size capはpure checked boundaryでexact値だけを許可する")
func codexNodeInspectorExecutableSizeHasExactBoundary() throws {
    try CodexNodeExecutableInspectionLimits.validateExecutableByteCount(
        CodexNodeExecutableInspectionLimits.maximumExecutableBytes
    )
    for byteCount: UInt64 in [
        0,
        CodexNodeExecutableInspectionLimits.maximumExecutableBytes + 1,
        UInt64.max
    ] {
        #expect(
            capturedNodeInspectionError {
                try CodexNodeExecutableInspectionLimits.validateExecutableByteCount(byteCount)
            } == .resourceLimit
        )
    }
}

private func nodeInspectionError(
    at executable: URL,
    architecture: CodexRuntimeArchitecture = .arm64
) -> CodexNodeExecutableInspectionError? {
    capturedNodeInspectionError {
        _ = try inspectSyntheticNodeExecutable(
            at: executable,
            architecture: architecture
        )
    }
}
