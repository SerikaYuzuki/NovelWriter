import Darwin
import Foundation
@testable import FUMINIWAExperimental
import Testing

@Test("raw invalid UTF-8 filesystem名をOSまたはreaddir検証で拒否する")
func codexDeploymentManifestRejectsInvalidFilesystemNameBytes() throws {
    let root = try makeManifestTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directoryDescriptor = root.path.withCString {
        Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    }
    guard directoryDescriptor >= 0 else {
        throw ManifestTestError.systemCallFailed
    }
    defer { Darwin.close(directoryDescriptor) }

    var invalidName: [CChar] = [0x69, 0x6E, -1, 0]
    let fileDescriptor = invalidName.withUnsafeMutableBufferPointer { name -> Int32 in
        guard let baseAddress = name.baseAddress else { return -1 }
        return Darwin.openat(
            directoryDescriptor,
            baseAddress,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            0o600
        )
    }
    if fileDescriptor < 0 {
        #expect(errno == EILSEQ)
        return
    }
    Darwin.close(fileDescriptor)
    defer {
        invalidName.withUnsafeMutableBufferPointer { name in
            guard let baseAddress = name.baseAddress else { return }
            _ = Darwin.unlinkat(directoryDescriptor, baseAddress, 0)
        }
    }

    #expect(manifestFilesystemCreationError(root) == .invalidPath)
}

@Test("self除外pathもsymlink・directory・hardlink・unsafe modeを拒否する")
func codexDeploymentManifestValidatesExcludedSelfTypeLinkAndMode() throws {
    let symlinkRoot = try makeManifestTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: symlinkRoot) }
    try writeManifestFile(root: symlinkRoot, relativePath: "target", contents: "x")
    let selfPath = symlinkRoot.appending(
        path: CodexDeploymentManifestLimits.selfManifestPath
    )
    #expect(symlink("target", selfPath.path) == 0)
    #expect(manifestFilesystemCreationError(symlinkRoot) == .symbolicLink)

    let directoryRoot = try makeManifestTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: directoryRoot) }
    try FileManager.default.createDirectory(
        at: directoryRoot.appending(path: CodexDeploymentManifestLimits.selfManifestPath),
        withIntermediateDirectories: false
    )
    #expect(manifestFilesystemCreationError(directoryRoot) == .unsupportedEntry)

    let hardlinkRoot = try makeManifestTemporaryRoot()
    let outsideHardlink = FileManager.default.temporaryDirectory
        .appending(path: "FUMINIWA-self-manifest-hardlink-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: hardlinkRoot)
        try? FileManager.default.removeItem(at: outsideHardlink)
    }
    let selfFile = try writeManifestFile(
        root: hardlinkRoot,
        relativePath: CodexDeploymentManifestLimits.selfManifestPath,
        contents: "self"
    )
    #expect(link(selfFile.path, outsideHardlink.path) == 0)
    #expect(manifestFilesystemCreationError(hardlinkRoot) == .hardLink)

    let modeRoot = try makeManifestTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: modeRoot) }
    let unsafeSelf = try writeManifestFile(
        root: modeRoot,
        relativePath: CodexDeploymentManifestLimits.selfManifestPath,
        contents: "self"
    )
    #expect(chmod(unsafeSelf.path, 0o666) == 0)
    #expect(manifestFilesystemCreationError(modeRoot) == .invalidMode)
}

@Test("self除外fileが検査後に変わればtree_changedで拒否する")
func codexDeploymentManifestValidatesExcludedSelfStability() throws {
    let root = try makeManifestTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let selfFile = try writeManifestFile(
        root: root,
        relativePath: CodexDeploymentManifestLimits.selfManifestPath,
        contents: "before"
    )
    let hooks = CodexDeploymentManifestTestingHooks(
        afterDirectoryTraversal: { relativePath in
            guard relativePath.isEmpty else { return }
            do {
                try Data("after".utf8).write(to: selfFile)
            } catch {
                Issue.record("self manifest mutation failed: \(error)")
            }
        }
    )
    #expect(
        capturedManifestError {
            _ = try CodexDeploymentManifestVerifier.create(
                rootPath: root.path,
                testingHooks: hooks
            )
        } == .treeChanged
    )
}

@Test("set-id・sticky modeとUnix socketを拒否する")
func codexDeploymentManifestRejectsSpecialModesAndSocket() throws {
    let setIDRoot = try makeManifestTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: setIDRoot) }
    let setIDFile = try writeManifestFile(
        root: setIDRoot,
        relativePath: "set-id",
        contents: "x"
    )
    #expect(chmod(setIDFile.path, 0o4644) == 0)
    #expect(manifestFilesystemCreationError(setIDRoot) == .invalidMode)

    let stickyRoot = try makeManifestTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: stickyRoot) }
    let stickyDirectory = stickyRoot.appending(path: "sticky", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: stickyDirectory,
        withIntermediateDirectories: false
    )
    #expect(chmod(stickyDirectory.path, 0o1755) == 0)
    #expect(manifestFilesystemCreationError(stickyRoot) == .invalidMode)

    let socketRoot = try makeShortManifestTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: socketRoot) }
    let socketDescriptor = try makeUnixSocket(at: socketRoot.appending(path: "socket"))
    defer { Darwin.close(socketDescriptor) }
    #expect(manifestFilesystemCreationError(socketRoot) == .unsupportedEntry)
}

@Test("file content mutationをtree_changedで拒否する")
func codexDeploymentManifestRejectsFileMutation() throws {
    let root = try makeManifestTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try writeManifestFile(root: root, relativePath: "main.mjs", contents: "before")
    let hooks = CodexDeploymentManifestTestingHooks(
        afterFileContentRead: { relativePath in
            guard relativePath == "main.mjs" else { return }
            do {
                try Data("after mutation".utf8).write(to: file)
            } catch {
                Issue.record("file mutation failed: \(error)")
            }
        }
    )
    #expect(
        capturedManifestError {
            _ = try CodexDeploymentManifestVerifier.create(
                rootPath: root.path,
                testingHooks: hooks
            )
        } == .treeChanged
    )
}

@Test("file pathのrename・inode swapをtree_changedで拒否する")
func codexDeploymentManifestRejectsFileInodeSwap() throws {
    let root = try makeManifestTemporaryRoot()
    let replacementRoot = try makeManifestTemporaryRoot()
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: replacementRoot)
    }
    let swappedFile = try writeManifestFile(
        root: root,
        relativePath: "main.mjs",
        contents: "original"
    )
    let displacedFile = replacementRoot.appending(path: "displaced")
    let replacementFile = try writeManifestFile(
        root: replacementRoot,
        relativePath: "replacement",
        contents: "replacement"
    )
    let hooks = CodexDeploymentManifestTestingHooks(
        afterFileContentRead: { relativePath in
            guard relativePath == "main.mjs" else { return }
            let displaced = rename(swappedFile.path, displacedFile.path) == 0
            let replaced = displaced
                && rename(replacementFile.path, swappedFile.path) == 0
            guard replaced else {
                Issue.record("inode swap failed")
                return
            }
        }
    )
    #expect(
        capturedManifestError {
            _ = try CodexDeploymentManifestVerifier.create(
                rootPath: root.path,
                testingHooks: hooks
            )
        } == .treeChanged
    )
}

@Test("directory mutationをtree_changedで拒否する")
func codexDeploymentManifestRejectsDirectoryMutation() throws {
    let root = try makeManifestTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try writeManifestFile(root: root, relativePath: "lib/main.mjs", contents: "x")
    let hooks = CodexDeploymentManifestTestingHooks(
        afterDirectoryTraversal: { relativePath in
            guard relativePath == "lib" else { return }
            do {
                try Data("late".utf8).write(to: root.appending(path: "lib/late.mjs"))
            } catch {
                Issue.record("directory mutation failed: \(error)")
            }
        }
    )
    #expect(
        capturedManifestError {
            _ = try CodexDeploymentManifestVerifier.create(
                rootPath: root.path,
                testingHooks: hooks
            )
        } == .treeChanged
    )
}

private func manifestFilesystemCreationError(
    _ root: URL
) -> CodexDeploymentManifestError? {
    capturedManifestError {
        _ = try CodexDeploymentManifestVerifier.create(rootPath: root.path)
    }
}
