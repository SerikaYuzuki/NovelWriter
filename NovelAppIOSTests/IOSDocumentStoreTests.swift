import Foundation
@testable import FUMINIWAIOS
import Testing

@MainActor
@Suite("iOS app-private document store")
struct IOSDocumentStoreTests {
    @Test("作品がない初回起動は自動作成せず作品棚になる")
    func bootstrapShowsEmptyLibraryWithoutCreatingDocument() async {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )

        await store.bootstrap()

        #expect(store.startupState == .library)
        #expect(store.libraryItems.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.documentURL.path))
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
        #expect(await firstStore.makeNewDocument())
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
        #expect(await sourceStore.makeNewDocument())
        sourceStore.updateDocumentTitle("取込元")
        #expect(await sourceStore.saveNow())
        let sourceURL = sourceStore.documentURL

        let destinationStore = IOSDocumentStore(
            userDefaults: destinationEnvironment.defaults,
            libraryRoot: destinationEnvironment.root
        )
        await destinationStore.bootstrap()
        #expect(await destinationStore.importPackage(from: sourceURL))

        #expect(destinationStore.startupState == .ready)
        #expect(destinationStore.document.title == "取込元")
        #expect(destinationStore.documentURL != sourceURL)
        #expect(destinationStore.documentURL.deletingLastPathComponent() == destinationEnvironment.root)
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))
        #expect(destinationStore.libraryItems.count == 1)
    }

    @Test("recent package欠損時は新規作品へfallbackせず作品棚を表示する")
    func missingRecentShowsLibrary() async throws {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let firstStore = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await firstStore.bootstrap()
        #expect(await firstStore.makeNewDocument())
        try FileManager.default.removeItem(at: firstStore.documentURL)

        let reopenedStore = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await reopenedStore.bootstrap()

        #expect(reopenedStore.startupState == .library)
        #expect(reopenedStore.libraryItems.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: reopenedStore.documentURL.path))
    }

    @Test("recent欠損時は別のavailable作品へ自動fallbackしない")
    func missingRecentDoesNotActivateAnotherAvailableDocument() async {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let firstStore = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await firstStore.bootstrap()
        #expect(await firstStore.makeNewDocument())
        firstStore.updateDocumentTitle("候補A")
        #expect(await firstStore.saveNow())
        #expect(await firstStore.makeNewDocument())
        firstStore.updateDocumentTitle("候補B")
        #expect(await firstStore.saveNow())
        environment.defaults.set("missing.novelpkg", forKey: "FUMINIWAIOS.lastDocumentName")

        let reopenedStore = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await reopenedStore.bootstrap()

        #expect(reopenedStore.startupState == .library)
        #expect(reopenedStore.libraryItems.count == 2)
        #expect(reopenedStore.libraryItems.allSatisfy { $0.availability == .available })
        #expect(
            environment.defaults.string(forKey: "FUMINIWAIOS.lastDocumentName") == "missing.novelpkg"
        )
    }

    @Test("recent破損時は作品棚で利用者の選択を待つ")
    func corruptRecentWaitsForExplicitAvailableDocumentSelection() async throws {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let firstStore = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await firstStore.bootstrap()
        #expect(await firstStore.makeNewDocument())
        firstStore.updateDocumentTitle("破損する作品")
        #expect(await firstStore.saveNow())
        let damagedURL = firstStore.documentURL
        #expect(await firstStore.makeNewDocument())
        firstStore.updateDocumentTitle("開ける作品")
        #expect(await firstStore.saveNow())
        let availableURL = firstStore.documentURL
        try Data("not-json".utf8).write(to: damagedURL.appendingPathComponent("manifest.json"))
        environment.defaults.set(damagedURL.lastPathComponent, forKey: "FUMINIWAIOS.lastDocumentName")

        let reopenedStore = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await reopenedStore.bootstrap()

        #expect(reopenedStore.startupState == .library)
        #expect(reopenedStore.libraryItems.count == 2)
        #expect(
            environment.defaults.string(forKey: "FUMINIWAIOS.lastDocumentName") == damagedURL.lastPathComponent
        )
        #expect(
            reopenedStore.libraryItems
                .first(where: { $0.id.packageName == damagedURL.lastPathComponent })?
                .availability == .unreadable
        )

        let availableID = try #require(
            reopenedStore.libraryItems.first(where: { $0.id.packageName == availableURL.lastPathComponent })?.id
        )
        #expect(await reopenedStore.openPrivateDocument(id: availableID))
        #expect(reopenedStore.startupState == .ready)
        #expect(reopenedStore.document.title == "開ける作品")
        #expect(
            environment.defaults.string(forKey: "FUMINIWAIOS.lastDocumentName") == availableURL.lastPathComponent
        )
    }

    @Test("recent以外も全て破損なら編集可能にせず作品棚を表示する")
    func allUnreadableDocumentsRemainInLibraryState() async throws {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let firstStore = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await firstStore.bootstrap()
        #expect(await firstStore.makeNewDocument())
        let damagedURL = firstStore.documentURL
        try Data("not-json".utf8).write(to: damagedURL.appendingPathComponent("manifest.json"))

        let reopenedStore = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await reopenedStore.bootstrap()

        #expect(reopenedStore.startupState == .library)
        #expect(reopenedStore.libraryItems.count == 1)
        #expect(reopenedStore.libraryItems.first?.availability == .unreadable)
        #expect(await !(reopenedStore.saveNow()))
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

        #expect(store.startupState == .library)
        #expect(store.libraryItems.isEmpty)
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
        #expect(await store.makeNewDocument())
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

@MainActor
@Suite("iOS document transition regressions")
private struct IOSDocumentTransitionRegressionTests {
    @Test("作品切替は変更通知前の最終本文も旧作品へ保存する")
    func transitionPersistsFinalModelStateToPreviousDocument() async throws {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let chapterID = try #require(store.selectedChapterID)
        let episodeID = try #require(store.selectedEpisodeID)
        let previousID = try #require(store.libraryItems.first?.id)

        // IME確定callbackがモデルを更新した直後、通常のdirty通知だけが遷移guardで
        // 抑止された状態を再現する。
        store.document.updateEpisodeContent("切替直前の確定本文", for: episodeID, in: chapterID)

        #expect(await store.makeNewDocument())
        #expect(await store.openPrivateDocument(id: previousID))
        #expect(store.document.episode(episodeID)?.episode.content == "切替直前の確定本文")
    }

    @Test("現在作品の明示選択でもrecentを現在packageへ更新する")
    func explicitlyOpeningCurrentDocumentUpdatesRecent() async throws {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let currentID = try #require(store.libraryItems.first?.id)
        environment.defaults.set("damaged.novelpkg", forKey: "FUMINIWAIOS.lastDocumentName")

        #expect(await store.openPrivateDocument(id: currentID))

        #expect(
            environment.defaults.string(forKey: "FUMINIWAIOS.lastDocumentName") == currentID.packageName
        )
    }

    private func makeEnvironment() -> TestEnvironment {
        let id = UUID().uuidString
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWA-iOS-Transition-Tests-\(id)", isDirectory: true)
        let suiteName = "dev.serikayuzuki.fuminiwa.ios.transition-tests.\(id)"
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
