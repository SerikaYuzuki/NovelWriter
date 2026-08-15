import Foundation
@testable import FUMINIWAIOS
import NovelCore
import NovelStorage
import Testing

@MainActor
@Suite("iOS app-private document library")
struct IOSDocumentLibraryTests {
    @Test("一覧はpackage basenameをidentityにして複数作品を保持する")
    func libraryUsesPackageBasenameIdentity() async {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let firstPackageName = store.documentURL.lastPathComponent

        #expect(await store.makeNewDocument())

        #expect(store.libraryItems.count == 2)
        #expect(Set(store.libraryItems.map(\.id.packageName)).count == 2)
        #expect(store.libraryItems.contains(where: { $0.id.packageName == firstPackageName }))
        #expect(store.libraryItems.allSatisfy { $0.id.packageName.hasSuffix(".novelpkg") })
    }

    @Test("タイトルと本文の変更を現在作品の一覧行へ同期する")
    func librarySynchronizesCurrentDocumentSummary() async throws {
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

        store.updateDocumentTitle("一覧へ反映する作品")
        store.updateDocumentSynopsis("作品情報のあらすじ")
        store.updateEpisodeContent("本文です", chapterID: chapterID, episodeID: episodeID)
        #expect(await store.refreshLibrary())

        let item = try #require(
            store.libraryItems.first(where: { $0.id.packageName == store.documentURL.lastPathComponent })
        )
        #expect(item.title == "一覧へ反映する作品")
        #expect(item.chapterCount == 1)
        #expect(item.episodeCount == 1)
        #expect(item.characterCount == 4)
        #expect(item.availability == .available)
        #expect(item.errorMessage == nil)
        #expect(store.document.synopsis == "作品情報のあらすじ")
    }

    @Test("破損packageは一覧の一行だけをunreadableにする")
    func refreshIsolatesUnreadablePackage() async throws {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let damagedURL = store.documentURL
        #expect(await store.makeNewDocument())
        let currentURL = store.documentURL
        try Data("not-json".utf8).write(to: damagedURL.appendingPathComponent("manifest.json"))

        #expect(await store.refreshLibrary())

        let damagedItem = try #require(
            store.libraryItems.first(where: { $0.id.packageName == damagedURL.lastPathComponent })
        )
        #expect(damagedItem.availability == .unreadable)
        #expect(damagedItem.errorMessage != nil)
        let currentItem = store.libraryItems.first {
            $0.id.packageName == currentURL.lastPathComponent
        }
        #expect(currentItem?.availability == .available)
        #expect(store.documentURL == currentURL)
    }

    @Test("検証済み一覧IDからだけ作品を開く")
    func openPrivateDocumentRequiresVerifiedID() async throws {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        store.updateDocumentTitle("最初の作品")
        let firstID = try #require(store.libraryItems.first?.id)
        #expect(await store.makeNewDocument())
        let secondURL = store.documentURL

        #expect(await store.openPrivateDocument(id: firstID))
        #expect(store.document.title == "最初の作品")
        #expect(store.documentURL.lastPathComponent == firstID.packageName)

        let invalidID = IOSPrivateDocumentID(packageName: "../outside.novelpkg")
        #expect(await !(store.openPrivateDocument(id: invalidID)))
        #expect(store.documentURL != secondURL)
        #expect(store.document.title == "最初の作品")
    }

    @Test("unreadable行は現在作品へ読み替えずopenを拒否する")
    func unreadableItemCannotBeOpened() async throws {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let damagedURL = store.documentURL
        #expect(await store.makeNewDocument())
        let currentURL = store.documentURL
        try Data("not-json".utf8).write(to: damagedURL.appendingPathComponent("manifest.json"))
        #expect(await store.refreshLibrary())
        let damagedID = try #require(
            store.libraryItems.first(where: { $0.id.packageName == damagedURL.lastPathComponent })?.id
        )

        #expect(await !(store.openPrivateDocument(id: damagedID)))
        #expect(store.documentURL == currentURL)
    }

    @Test("隠しstagingとsymlinkは作品一覧へ出さない")
    func refreshIgnoresUnstableOrLinkedPackages() async throws {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let visibleCount = store.libraryItems.count
        let hiddenURL = environment.root.appendingPathComponent(".import-test.novelpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: hiddenURL, withIntermediateDirectories: true)
        let linkedURL = environment.root.appendingPathComponent("linked.novelpkg", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedURL, withDestinationURL: store.documentURL)

        #expect(await store.refreshLibrary())

        #expect(store.libraryItems.count == visibleCount)
        #expect(!store.libraryItems.contains(where: { $0.id.packageName == hiddenURL.lastPathComponent }))
        #expect(!store.libraryItems.contains(where: { $0.id.packageName == linkedURL.lastPathComponent }))
    }

    @Test("同じdocument IDの再取込も別のworking-copy行として保持する")
    func repeatedImportKeepsDistinctWorkingCopies() async {
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
        sourceStore.updateDocumentTitle("複製する作品")
        #expect(await sourceStore.saveNow())

        let destinationStore = IOSDocumentStore(
            userDefaults: destinationEnvironment.defaults,
            libraryRoot: destinationEnvironment.root
        )
        await destinationStore.bootstrap()
        #expect(await destinationStore.importPackage(from: sourceStore.documentURL))
        #expect(await destinationStore.importPackage(from: sourceStore.documentURL))

        let copies = destinationStore.libraryItems.filter { $0.title == "複製する作品" }
        #expect(copies.count == 2)
        #expect(Set(copies.map(\.id)).count == 2)
    }

    @Test("不正packageの取込失敗は現在作品と一覧を維持する")
    func failedImportReturnsFalseWithoutChangingLibrary() async throws {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await store.bootstrap()
        #expect(await store.makeNewDocument())
        let currentURL = store.documentURL
        let currentItems = store.libraryItems
        let invalidURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("invalid-\(UUID().uuidString).novelpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: invalidURL) }

        #expect(await !(store.importPackage(from: invalidURL)))
        #expect(store.documentURL == currentURL)
        #expect(store.libraryItems == currentItems)
    }

    private func makeEnvironment() -> LibraryTestEnvironment {
        let id = UUID().uuidString
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWA-iOS-Library-Tests-\(id)", isDirectory: true)
        let suiteName = "dev.serikayuzuki.fuminiwa.ios.library-tests.\(id)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return LibraryTestEnvironment(root: root, defaults: defaults, suiteName: suiteName)
    }
}

@MainActor
@Suite("iOS document library concurrency regressions")
private struct IOSDocumentLibraryConcurrencyTests {
    @Test("古いrefreshは作品切替後の新しい一覧を上書きしない")
    func staleRefreshCannotOverwriteNewerLibraryGeneration() async {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let setupStore = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await setupStore.bootstrap()
        #expect(await setupStore.makeNewDocument())
        setupStore.updateDocumentTitle("作品A")
        #expect(await setupStore.saveNow())
        #expect(await setupStore.makeNewDocument())
        setupStore.updateDocumentTitle("作品B")
        #expect(await setupStore.saveNow())

        let repository = PausingCopyingRepository()
        let store = IOSDocumentStore(
            repository: repository,
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await store.bootstrap()
        #expect(store.startupState == .ready)
        #expect(store.libraryItems.count == 2)

        await repository.pauseNextLoad()
        let staleRefresh = Task { await store.refreshLibrary() }
        await repository.waitUntilLoadIsPaused()

        #expect(await store.makeNewDocument())
        let newestPackageName = store.documentURL.lastPathComponent
        #expect(store.libraryItems.count == 3)

        await repository.resumeLoad()
        #expect(await staleRefresh.value)
        #expect(store.libraryItems.count == 3)
        #expect(store.libraryItems.contains(where: { $0.id.packageName == newestPackageName }))
    }

    @Test("候補一件のresource metadata失敗は作品棚全体をRecoveryにしない")
    func candidateResourceMetadataFailureIsSkipped() async {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        let setupStore = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await setupStore.bootstrap()
        #expect(await setupStore.makeNewDocument())
        setupStore.updateDocumentTitle("読める作品")
        #expect(await setupStore.saveNow())
        let validURL = setupStore.documentURL
        let missingMetadataURL = environment.root.appendingPathComponent(
            "vanished.novelpkg",
            isDirectory: true
        )
        let fileManager = CandidateListFileManager(
            root: environment.root,
            candidates: [missingMetadataURL, validURL]
        )

        let reopenedStore = IOSDocumentStore(
            fileManager: fileManager,
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await reopenedStore.bootstrap()

        #expect(reopenedStore.startupState == .ready)
        #expect(reopenedStore.libraryItems.count == 1)
        #expect(reopenedStore.libraryItems.first?.title == "読める作品")
    }

    private func makeEnvironment() -> LibraryTestEnvironment {
        let id = UUID().uuidString
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWA-iOS-Library-Concurrency-Tests-\(id)", isDirectory: true)
        let suiteName = "dev.serikayuzuki.fuminiwa.ios.library-concurrency-tests.\(id)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return LibraryTestEnvironment(root: root, defaults: defaults, suiteName: suiteName)
    }
}

private struct LibraryTestEnvironment {
    let root: URL
    let defaults: UserDefaults
    let suiteName: String

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private actor PausingCopyingRepository: DocumentCopyingRepository {
    private let base = NovelpkgRepository()
    private var shouldPauseNextLoad = false
    private var pausedLoadContinuation: CheckedContinuation<Void, Never>?

    func pauseNextLoad() {
        shouldPauseNextLoad = true
    }

    func waitUntilLoadIsPaused() async {
        while pausedLoadContinuation == nil {
            await Task.yield()
        }
    }

    func resumeLoad() {
        pausedLoadContinuation?.resume()
        pausedLoadContinuation = nil
    }

    func load(from url: URL) async throws -> NovelDocument {
        if shouldPauseNextLoad {
            shouldPauseNextLoad = false
            await withCheckedContinuation { continuation in
                pausedLoadContinuation = continuation
            }
        }
        return try await base.load(from: url)
    }

    func save(_ doc: NovelDocument, to url: URL) async throws {
        try await base.save(doc, to: url)
    }

    func saveCopy(_ doc: NovelDocument, from sourceURL: URL, to destinationURL: URL) async throws {
        try await base.saveCopy(doc, from: sourceURL, to: destinationURL)
    }
}

private final class CandidateListFileManager: FileManager, @unchecked Sendable {
    private let root: URL
    private let candidates: [URL]

    init(root: URL, candidates: [URL]) {
        self.root = root.standardizedFileURL
        self.candidates = candidates
        super.init()
    }

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        guard url.standardizedFileURL == root else {
            return try super.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: mask
            )
        }
        return candidates
    }
}
