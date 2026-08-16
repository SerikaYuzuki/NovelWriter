import Foundation
@testable import FUMINIWAIOS
import NovelCore
import NovelStorage
import Testing

@MainActor
@Suite("iOS private working-copy proof", .serialized)
struct IOSPrivateWorkingCopyLocationTests {
    @Test("trusted baseだけをcanonicalizeしroot差し替えを拒否する")
    func canonicalTrustedBaseRejectsRootReplacement() throws {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let fileManager = FileManager.default

        let realBase = environment.root.appendingPathComponent("real-base", isDirectory: true)
        try fileManager.createDirectory(at: realBase, withIntermediateDirectories: true)
        let trustedAlias = environment.root.appendingPathComponent("trusted-alias", isDirectory: true)
        try fileManager.createSymbolicLink(at: trustedAlias, withDestinationURL: realBase)
        let requestedRoot = trustedAlias
            .appendingPathComponent("Library/Application Support/FUMINIWA/Works", isDirectory: true)
        let location = try IOSPrivateWorkingCopyLocation.prepare(
            requestedRootURL: requestedRoot,
            trustedSandboxBaseURL: trustedAlias
        )
        #expect(location.rootURL.path.hasPrefix(realBase.path + "/"))
        try location.validateFixedRoot()

        let movedRoot = realBase.appendingPathComponent("moved-works", isDirectory: true)
        try fileManager.moveItem(at: location.rootURL, to: movedRoot)
        try fileManager.createDirectory(at: location.rootURL, withIntermediateDirectories: false)
        #expect(throws: IOSPrivateWorkingCopyLocationError.unsafeRoot) {
            try location.validateFixedRoot()
        }
    }

    @Test("private rootまでのancestorとfinal symlinkを拒否する")
    func relativeRootComponentsRejectAncestorAndFinalSymlinks() throws {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let fileManager = FileManager.default

        let ancestorBase = environment.root.appendingPathComponent("ancestor-base", isDirectory: true)
        let ancestorTarget = environment.root.appendingPathComponent("ancestor-target", isDirectory: true)
        try fileManager.createDirectory(at: ancestorBase, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: ancestorTarget, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: ancestorBase.appendingPathComponent("Library", isDirectory: true),
            withDestinationURL: ancestorTarget
        )
        #expect(throws: IOSPrivateWorkingCopyLocationError.unsafeRoot) {
            _ = try IOSPrivateWorkingCopyLocation.prepare(
                requestedRootURL: ancestorBase
                    .appendingPathComponent("Library/Application Support/FUMINIWA/Works", isDirectory: true),
                trustedSandboxBaseURL: ancestorBase
            )
        }

        let finalBase = environment.root.appendingPathComponent("final-base", isDirectory: true)
        let finalTarget = environment.root.appendingPathComponent("final-target", isDirectory: true)
        let finalParent = finalBase
            .appendingPathComponent("Library/Application Support/FUMINIWA", isDirectory: true)
        try fileManager.createDirectory(at: finalParent, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: finalTarget, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: finalParent.appendingPathComponent("Works", isDirectory: true),
            withDestinationURL: finalTarget
        )
        #expect(throws: IOSPrivateWorkingCopyLocationError.unsafeRoot) {
            _ = try IOSPrivateWorkingCopyLocation.prepare(
                requestedRootURL: finalParent.appendingPathComponent("Works", isDirectory: true),
                trustedSandboxBaseURL: finalBase
            )
        }
    }

    @Test("symlink library rootのStoreは起動と新規作成をside effectなしで拒否する")
    func storeRejectsSymlinkRootWithoutSideEffects() async throws {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let fileManager = FileManager.default
        let target = environment.root.appendingPathComponent("linked-target", isDirectory: true)
        let linkedRoot = environment.root.appendingPathComponent("linked-library", isDirectory: true)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: linkedRoot, withDestinationURL: target)

        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: linkedRoot
        )
        #expect(store.deviceSyncStartupFailedSafely)
        await store.bootstrap()
        #expect(await !(store.makeNewDocument()))
        #expect(store.currentPrivateDocumentID == nil)
        #expect(try fileManager.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test("external packageは現在作品として直接installできない")
    func externalPackageCannotBeInstalledDirectly() async throws {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let externalPackage = environment.root.appendingPathComponent("external.novelpkg", isDirectory: true)
        let document = NovelDocument.newDocument(title: "外部作品")
        try await NovelpkgRepository().save(document, to: externalPackage)
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root.appendingPathComponent("private-library", isDirectory: true)
        )
        await store.bootstrap()

        #expect(!store.install(document, at: externalPackage, attachments: []))
        #expect(store.deviceSyncStartupFailedSafely)
        #expect(store.currentPrivateDocumentID == nil)
        #expect(environment.defaults.string(forKey: IOSDocumentStore.lastDocumentNameKey) == nil)
    }

    @Test("package symlinkはremote operation前に拒否しside effectを起こさない")
    func packageSymlinkIsRejectedBeforeRemoteOperation() async throws {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let fileManager = FileManager.default
        let location = try makeLocation(in: environment.root)
        let outside = environment.root.appendingPathComponent("outside.novelpkg", isDirectory: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        let id = IOSPrivateDocumentID(packageName: "linked.novelpkg")
        let linked = location.rootURL.appendingPathComponent(id.packageName, isDirectory: true)
        try fileManager.createSymbolicLink(at: linked, withDestinationURL: outside)
        let sideEffects = IOSPrivateWorkingCopyTestCounter()

        await #expect(throws: IOSPrivateWorkingCopyLocationError.unsafeRoot) {
            _ = try await location.performWithAttestedPackage(for: id) {
                await sideEffects.increment()
                return 1
            }
        }
        #expect(await sideEffects.value == 0)
    }

    @Test("paused lookup中のpackage差し替えは古いattestationで結果を受理しない")
    func pausedLookupRejectsPackageReplacement() async throws {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let fileManager = FileManager.default
        let location = try makeLocation(in: environment.root)
        let id = IOSPrivateDocumentID(packageName: "paused.novelpkg")
        let packageURL = try location.destination(for: id)
        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: false)
        let pausedLookup = IOSPrivateWorkingCopyPausedLookup()

        let lookupTask = Task {
            do {
                let value = try await location.performWithAttestedPackage(for: id) {
                    await pausedLookup.run()
                }
                return Result<Int, any Error>.success(value)
            } catch {
                return Result<Int, any Error>.failure(error)
            }
        }
        await pausedLookup.waitUntilPaused()

        let moved = location.rootURL.appendingPathComponent("moved.novelpkg", isDirectory: true)
        try fileManager.moveItem(at: packageURL, to: moved)
        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: false)
        await pausedLookup.resume(returning: 42)

        switch await lookupTask.value {
        case .success:
            Issue.record("差し替え後のlookup結果を受理しました")
        case let .failure(error):
            #expect(error as? IOSPrivateWorkingCopyLocationError == .unsafeRoot)
        }
    }

    @Test("symlink packageのimportは原本を辿らず現在作品とrecentを作らない")
    func importRejectsSymlinkPackageWithoutAdoption() async throws {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let fileManager = FileManager.default
        let externalPackage = environment.root.appendingPathComponent("external.novelpkg", isDirectory: true)
        let linkedSource = environment.root.appendingPathComponent("linked-source.novelpkg", isDirectory: true)
        let document = NovelDocument.newDocument(title: "外部原本")
        try await NovelpkgRepository().save(document, to: externalPackage)
        try fileManager.createSymbolicLink(at: linkedSource, withDestinationURL: externalPackage)

        let libraryRoot = environment.root.appendingPathComponent("private-library", isDirectory: true)
        let store = IOSDocumentStore(
            repository: NovelpkgRepository(),
            userDefaults: environment.defaults,
            libraryRoot: libraryRoot
        )
        await store.bootstrap()
        #expect(store.startupState == .library)

        #expect(await !store.importPackage(from: linkedSource))
        #expect(store.startupState == .library)
        #expect(store.currentPrivateDocumentID == nil)
        #expect(store.libraryItems.isEmpty)
        #expect(environment.defaults.string(forKey: IOSDocumentStore.lastDocumentNameKey) == nil)
        #expect(fileManager.fileExists(atPath: externalPackage.path))
        let privateItems = try fileManager.contentsOfDirectory(
            at: store.libraryRoot,
            includingPropertiesForKeys: nil
        )
        let adoptedPackages = privateItems.filter { item in
            item.pathExtension == "novelpkg"
                || item.lastPathComponent.hasPrefix(".import-")
                || item.lastPathComponent.hasSuffix(".staging.novelpkg")
        }
        #expect(adoptedPackages.isEmpty)
    }

    private func makeLocation(in sandbox: URL) throws -> IOSPrivateWorkingCopyLocation {
        let trustedBase = sandbox.appendingPathComponent("sandbox", isDirectory: true)
        try FileManager.default.createDirectory(at: trustedBase, withIntermediateDirectories: true)
        return try IOSPrivateWorkingCopyLocation.prepare(
            requestedRootURL: trustedBase
                .appendingPathComponent("Library/Application Support/FUMINIWA/Works", isDirectory: true),
            trustedSandboxBaseURL: trustedBase
        )
    }

    private func makeEnvironment() -> IOSPrivateWorkingCopyTestEnvironment {
        let id = UUID().uuidString
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWA-iOS-Private-Working-Copy-Tests-\(id)", isDirectory: true)
        let suiteName = "dev.serikayuzuki.fuminiwa.ios.private-working-copy-tests.\(id)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return IOSPrivateWorkingCopyTestEnvironment(
            root: root,
            defaults: defaults,
            suiteName: suiteName
        )
    }
}

private actor IOSPrivateWorkingCopyTestCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor IOSPrivateWorkingCopyPausedLookup {
    private var continuation: CheckedContinuation<Int, Never>?

    func run() async -> Int {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilPaused() async {
        while continuation == nil {
            await Task.yield()
        }
    }

    func resume(returning value: Int) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

private struct IOSPrivateWorkingCopyTestEnvironment {
    let root: URL
    let defaults: UserDefaults
    let suiteName: String

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
