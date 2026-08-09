import Foundation
@testable import FUMINIWAIOS
import Testing

@MainActor
@Suite("iOS app-private document store")
struct IOSDocumentStoreTests {
    @Test("初回起動はapp-private packageを作成してReadyになる")
    func bootstrapCreatesPrivateWorkingCopy() async {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )

        await store.bootstrap()

        #expect(store.startupState == .ready)
        #expect(store.documentURL.deletingLastPathComponent() == environment.root)
        #expect(FileManager.default.fileExists(atPath: store.documentURL.path))
    }

    @Test("明示保存した本文状態を次回起動で復元する")
    func saveAndReloadUsesRecentPrivatePackage() async {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let firstStore = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await firstStore.bootstrap()
        firstStore.updateDocumentTitle("保存した作品")
        #expect(await firstStore.saveNow())

        let reopenedStore = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await reopenedStore.bootstrap()

        #expect(reopenedStore.startupState == .ready)
        #expect(reopenedStore.document.title == "保存した作品")
        #expect(reopenedStore.documentURL == firstStore.documentURL)
    }

    @Test("取込は原本とは別のapp-private packageを採用する")
    func importCopiesWithoutAdoptingSourceURL() async {
        let sourceEnvironment = makeEnvironment()
        let destinationEnvironment = makeEnvironment()
        defer {
            sourceEnvironment.cleanup()
            destinationEnvironment.cleanup()
        }

        let sourceStore = IOSDocumentStore(
            userDefaults: sourceEnvironment.defaults,
            libraryRoot: sourceEnvironment.root
        )
        await sourceStore.bootstrap()
        sourceStore.updateDocumentTitle("取込元")
        #expect(await sourceStore.saveNow())
        let sourceURL = sourceStore.documentURL

        let destinationStore = IOSDocumentStore(
            userDefaults: destinationEnvironment.defaults,
            libraryRoot: destinationEnvironment.root
        )
        await destinationStore.bootstrap()
        await destinationStore.importPackage(from: sourceURL)

        #expect(destinationStore.startupState == .ready)
        #expect(destinationStore.document.title == "取込元")
        #expect(destinationStore.documentURL != sourceURL)
        #expect(destinationStore.documentURL.deletingLastPathComponent() == destinationEnvironment.root)
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    @Test("recent package欠損時は新規作品へfallbackしない")
    func missingRecentStopsInRecovery() async throws {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let firstStore = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await firstStore.bootstrap()
        try FileManager.default.removeItem(at: firstStore.documentURL)

        let reopenedStore = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await reopenedStore.bootstrap()

        guard case .recovery = reopenedStore.startupState else {
            Issue.record("recent package欠損時にRecoveryへ遷移しませんでした")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: reopenedStore.documentURL.path))
    }

    @Test("recent名からapp-private領域外を参照しない")
    func recentNameRejectsPathTraversal() async {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        environment.defaults.set("../outside.novelpkg", forKey: "FUMINIWAIOS.lastDocumentName")
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )

        await store.bootstrap()

        guard case .recovery = store.startupState else {
            Issue.record("不正なrecent名をRecoveryで拒否しませんでした")
            return
        }
    }

    @Test("書出しは編集中packageとは別の安定したcopyを作る")
    func exportCreatesSeparateSnapshotPackage() async throws {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await store.bootstrap()
        store.updateDocumentTitle("共有用")

        await store.requestExport()

        let exportURL = try #require(store.pendingExportURL)
        #expect(exportURL != store.documentURL)
        #expect(exportURL.lastPathComponent == "共有用.novelpkg")
        #expect(FileManager.default.fileExists(atPath: exportURL.path))
        store.dismissExport()
        #expect(!FileManager.default.fileExists(atPath: exportURL.path))
    }

    private func makeEnvironment() -> TestEnvironment {
        let id = UUID().uuidString
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWA-iOS-Tests-\(id)", isDirectory: true)
        let suiteName = "dev.serikayuzuki.fuminiwa.ios.tests.\(id)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return TestEnvironment(root: root, defaults: defaults, suiteName: suiteName)
    }
}

private struct TestEnvironment {
    let root: URL
    let defaults: UserDefaults
    let suiteName: String

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
