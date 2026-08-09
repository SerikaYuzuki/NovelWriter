import Darwin
import Foundation
@testable import FUMINIWAExperimental
import Testing

@Test("initial lstat後のcontent mutationを拒否する")
func codexNodeInspectorRejectsMutationAfterInitialLstat() throws {
    let fixture = try makeMutationFixture()
    defer { fixture.remove() }
    let hooks = CodexNodeExecutableInspectorTestingHooks(
        afterInitialLstat: {
            mutateNodeFixture(at: fixture.executable)
        }
    )

    #expect(mutationInspectionError(fixture.executable, hooks: hooks) == .fileChanged)
}

@Test("hash後とsignature観測後のcontent mutationを拒否する")
func codexNodeInspectorRejectsPostReadMutations() throws {
    for stage in [MutationStage.postHashAndMachORead, .postSignature] {
        let fixture = try makeMutationFixture()
        defer { fixture.remove() }
        let hooks = stage.hooks {
            mutateNodeFixture(at: fixture.executable)
        }
        #expect(mutationInspectionError(fixture.executable, hooks: hooks) == .fileChanged)
    }
}

@Test("open前とhash後のrename/inode swapを拒否する")
func codexNodeInspectorRejectsInodeSwaps() throws {
    for stage in [MutationStage.preOpen, .postHashAndMachORead, .postSignature] {
        let fixture = try makeMutationFixture()
        defer { fixture.remove() }
        let hooks = stage.hooks {
            swapNodeFixture(fixture)
        }
        #expect(mutationInspectionError(fixture.executable, hooks: hooks) == .fileChanged)
    }
}

@Test("initial lstat後のFIFO swapはblockせずfail-closedになる")
func codexNodeInspectorRejectsFIFOInodeSwapWithoutBlocking() throws {
    let fixture = try makeMutationFixture()
    defer { fixture.remove() }
    let hooks = CodexNodeExecutableInspectorTestingHooks(
        afterInitialLstat: {
            let renamed = rename(
                fixture.executable.path,
                fixture.displaced.path
            ) == 0
            guard renamed else {
                Issue.record("failed to displace executable before FIFO swap")
                return
            }
            do {
                try makeNodeInspectorFIFO(at: fixture.executable)
            } catch {
                Issue.record("failed to install FIFO replacement: \(error)")
            }
        }
    )
    let error = mutationInspectionError(fixture.executable, hooks: hooks)
    #expect(error == .fileChanged || error == .notRegularFile)
}

@Test("signature後にancestorをsymlink aliasへ替えてもcanonical再検査で拒否する")
func codexNodeInspectorRechecksCanonicalPathAfterSignature() throws {
    let fixture = try makeMutationFixture()
    let originalRoot = fixture.root
    let displacedRoot = fixture.root.deletingLastPathComponent().appending(
        path: "fn-node-displaced-root-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    defer {
        try? FileManager.default.removeItem(at: originalRoot)
        try? FileManager.default.removeItem(at: displacedRoot)
    }
    let hooks = CodexNodeExecutableInspectorTestingHooks(
        afterCodeSignatureObservation: {
            let renamed = rename(originalRoot.path, displacedRoot.path) == 0
            let aliased = renamed && symlink(displacedRoot.path, originalRoot.path) == 0
            guard aliased else {
                Issue.record("failed to replace ancestor with symlink alias")
                return
            }
        }
    )

    #expect(mutationInspectionError(fixture.executable, hooks: hooks) == .fileChanged)
}

private enum MutationStage {
    case preOpen
    case postHashAndMachORead
    case postSignature

    func hooks(
        operation: @escaping @Sendable () -> Void
    ) -> CodexNodeExecutableInspectorTestingHooks {
        switch self {
        case .preOpen:
            CodexNodeExecutableInspectorTestingHooks(afterInitialLstat: operation)
        case .postHashAndMachORead:
            CodexNodeExecutableInspectorTestingHooks(afterFileContentRead: operation)
        case .postSignature:
            CodexNodeExecutableInspectorTestingHooks(afterCodeSignatureObservation: operation)
        }
    }
}

private struct MutationFixture: Sendable {
    let root: URL
    let executable: URL
    let replacement: URL
    let displaced: URL

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func makeMutationFixture() throws -> MutationFixture {
    let root = try makeNodeInspectorTemporaryRoot()
    let executable = try writeSyntheticNodeExecutable(root: root)
    let replacement = try writeSyntheticNodeExecutable(
        root: root,
        relativePath: "replacement/node",
        contents: syntheticThinMachO(architecture: .arm64) + Data([0xA5])
    )
    return MutationFixture(
        root: root,
        executable: executable,
        replacement: replacement,
        displaced: root.appending(path: "displaced-node")
    )
}

private func mutateNodeFixture(at executable: URL) {
    do {
        try syntheticThinMachO(architecture: .x64).write(to: executable)
        guard chmod(executable.path, 0o700) == 0 else {
            Issue.record("failed to restore executable mode after mutation")
            return
        }
    } catch {
        Issue.record("failed to mutate executable fixture: \(error)")
    }
}

private func swapNodeFixture(_ fixture: MutationFixture) {
    let displaced = rename(fixture.executable.path, fixture.displaced.path) == 0
    let replaced = displaced
        && rename(fixture.replacement.path, fixture.executable.path) == 0
    guard replaced else {
        Issue.record("failed to swap executable inode")
        return
    }
}

private func mutationInspectionError(
    _ executable: URL,
    hooks: CodexNodeExecutableInspectorTestingHooks
) -> CodexNodeExecutableInspectionError? {
    capturedNodeInspectionError {
        _ = try inspectSyntheticNodeExecutable(
            at: executable,
            testingHooks: hooks
        )
    }
}
