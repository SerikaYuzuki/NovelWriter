// swiftlint:disable file_length
import AppKit
import Foundation
@testable import FUMINIWA
import NovelCore
import SwiftUI
import Testing

@MainActor
struct AppStateBootstrapTests {
    @Test("起動直後は編集可能なreadyではない")
    func startsInLoadingState() {
        let state = makeState(repository: BootstrapRepository(), defaults: makeUserDefaults())

        #expect(state.startupState == .loading)
        #expect(!state.startupState.isReady)
    }

    @Test("通常起動は前回作品を読み込まず選択画面で待つ")
    func recentDocumentAppearsInSelectionWithoutIO() async throws {
        let repository = BootstrapRepository()
        let defaults = makeUserDefaults()
        let url = packageURL("前回作品")
        let document = NovelDocument.newDocument(title: "続きから")
        await repository.seed(document, at: url)
        defaults.set(url.path, forKey: AppPreferenceKey.recentDocumentPath)
        let state = makeState(repository: repository, defaults: defaults)

        await state.bootstrap()

        let context = try #require(documentSelectionContext(in: state))
        #expect(context.recentDocument?.url == url.standardizedFileURL)
        #expect(context.recentDocument?.displayName == "前回作品")
        #expect(!state.startupState.isReady)
        #expect(await repository.loadCount == 0)
        #expect(await repository.saveCount == 0)
        #expect(defaults.string(forKey: AppPreferenceKey.recentDocumentPath) == url.path)
    }

    @Test("選択画面で前回作品を明示した後だけ読み込んでreadyにする")
    func selectedRecentDocumentBecomesReadyWithoutSaving() async {
        let repository = BootstrapRepository()
        let defaults = makeUserDefaults()
        let url = packageURL("選んだ前回作品")
        let document = NovelDocument.newDocument(title: "選択後に開く")
        await repository.seed(document, at: url)
        defaults.set(url.path, forKey: AppPreferenceKey.recentDocumentPath)
        let state = makeState(repository: repository, defaults: defaults)

        await state.bootstrap()
        let session = state.documentSessionToken

        #expect(await state.openRecentDocument(expectedSession: session))
        #expect(state.startupState == .ready)
        #expect(state.document == document)
        #expect(state.documentURL == url.standardizedFileURL)
        #expect(await repository.loadCount == 1)
        #expect(await repository.saveCount == 0)
        #expect(defaults.string(forKey: AppPreferenceKey.recentDocumentPath) == url.path)
    }

    @Test("選んだ前回作品を開けないときは保存もrecent更新もせずRecoveryで止まる")
    func selectedRecentDocumentFailureFailsClosed() async {
        let repository = BootstrapRepository(loadFails: true)
        let defaults = makeUserDefaults()
        let url = packageURL("開けない作品")
        defaults.set(url.path, forKey: AppPreferenceKey.recentDocumentPath)
        let state = makeState(repository: repository, defaults: defaults)

        await state.bootstrap()
        let session = state.documentSessionToken
        #expect(await state.openRecentDocument(expectedSession: session) == false)

        guard case let .recovery(context) = state.startupState else {
            Issue.record("Recoveryへ移行しませんでした")
            return
        }
        #expect(context.reason == .cannotOpenDocument)
        #expect(context.source == .recentDocument)
        #expect(context.documentURL?.path == url.standardizedFileURL.path)
        #expect(await repository.saveCount == 0)
        #expect(defaults.string(forKey: AppPreferenceKey.recentDocumentPath) == url.path)
        #expect(await state.saveBeforeTermination())
        #expect(await repository.saveCount == 0)
    }

    @Test("Recoveryの再試行は同じURLを開き直す")
    func retryUsesSameDocumentURL() async {
        let repository = BootstrapRepository(loadFails: true)
        let defaults = makeUserDefaults()
        let url = packageURL("再試行作品")
        let document = NovelDocument.newDocument(title: "復帰")
        await repository.seed(document, at: url)
        defaults.set(url.path, forKey: AppPreferenceKey.recentDocumentPath)
        let state = makeState(repository: repository, defaults: defaults)

        await state.bootstrap()
        #expect(await state.openRecentDocument(expectedSession: state.documentSessionToken) == false)
        await repository.setLoadFailure(false)
        await state.retryStartup()

        #expect(state.startupState == .ready)
        #expect(state.document == document)
        #expect(state.documentURL.path == url.standardizedFileURL.path)
        #expect(await repository.loadCount == 2)
        #expect(await repository.saveCount == 0)
    }

    @Test("recentが無い初回起動も作品を自動作成せず選択画面で待つ")
    func initialLaunchWithoutRecentWaitsForSelection() async throws {
        let repository = BootstrapRepository()
        let defaults = makeUserDefaults()
        let state = makeState(repository: repository, defaults: defaults)

        await state.bootstrap()

        let context = try #require(documentSelectionContext(in: state))
        #expect(context.recentDocument == nil)
        #expect(!state.startupState.isReady)
        #expect(await repository.loadCount == 0)
        #expect(await repository.saveCount == 0)
        #expect(defaults.string(forKey: AppPreferenceKey.recentDocumentPath) == nil)
    }

    @Test("選択画面から明示した新規作品は保存成功後だけ採用する")
    func explicitNewDocumentFromSelectionChangesRecentAfterSave() async {
        let repository = BootstrapRepository()
        let defaults = makeUserDefaults()
        let state = makeState(repository: repository, defaults: defaults)

        await state.bootstrap()
        let session = state.documentSessionToken

        #expect(await state.createNewDocument(expectedSession: session))
        #expect(state.startupState == .ready)
        #expect(state.document.title == "新規作品")
        #expect(state.documentSessionToken != session)
        #expect(await repository.loadCount == 0)
        #expect(await repository.saveCount == 1)
        #expect(defaults.string(forKey: AppPreferenceKey.recentDocumentPath) == state.documentURL.path)
    }

    @Test("選択画面から明示した新規保存の失敗はrecentを作らない")
    func explicitInitialDocumentSaveFailureEntersRecovery() async {
        let repository = BootstrapRepository(saveFails: true)
        let defaults = makeUserDefaults()
        let state = makeState(repository: repository, defaults: defaults)

        await state.bootstrap()
        #expect(await state.createNewDocument(expectedSession: state.documentSessionToken) == false)

        guard case let .recovery(context) = state.startupState else {
            Issue.record("Recoveryへ移行しませんでした")
            return
        }
        #expect(context.reason == .cannotCreateDocument)
        #expect(context.source == .initialDocument)
        #expect(defaults.string(forKey: AppPreferenceKey.recentDocumentPath) == nil)
        #expect(await repository.saveCount == 1)
    }

    @Test("bootstrapを二度呼んでも作品を読み書きしない")
    func bootstrapIsIdempotent() async {
        let repository = BootstrapRepository()
        let state = makeState(repository: repository, defaults: makeUserDefaults())

        await state.bootstrap()
        await state.bootstrap()

        #expect(documentSelectionContext(in: state) != nil)
        #expect(await repository.loadCount == 0)
        #expect(await repository.saveCount == 0)
    }

    @Test("同時bootstrapは先行Finder読込の同じ完了へ合流する")
    func concurrentBootstrapWaitsForSharedCompletion() async {
        let repository = BootstrapRepository()
        let finderURL = packageURL("待機中のFinder作品")
        let finderDocument = NovelDocument.newDocument(title: "Finderから")
        await repository.seed(finderDocument, at: finderURL)
        await repository.pauseLoad(at: finderURL)
        let state = makeState(repository: repository, defaults: makeUserDefaults())

        var initialBootstrapDidReturn = false
        let initialBootstrap = Task { @MainActor in
            await state.bootstrap(opening: finderURL)
            initialBootstrapDidReturn = true
        }
        let didPause = await repository.waitUntilLoadIsPaused(at: finderURL)

        var joinedBootstrapDidReturn = false
        let joinedBootstrap = Task { @MainActor in
            await state.bootstrap()
            joinedBootstrapDidReturn = true
        }
        await allowTasksToRun()

        #expect(didPause)
        #expect(!initialBootstrapDidReturn)
        #expect(!joinedBootstrapDidReturn)
        #expect(state.startupState == .loading)

        await repository.resumeLoad(at: finderURL)
        await initialBootstrap.value
        await joinedBootstrap.value

        #expect(initialBootstrapDidReturn)
        #expect(joinedBootstrapDidReturn)
        #expect(state.startupState == .ready)
        #expect(state.document == finderDocument)
        #expect(state.documentURL == finderURL.standardizedFileURL)
        #expect(await repository.loadCount == 1)
    }

    @Test("先行bootstrapは起動中に追加されたFinder読込まで待つ")
    func initialBootstrapWaitsForQueuedFinderLoad() async {
        let repository = BootstrapRepository()
        let firstURL = packageURL("先行Finder作品")
        let queuedURL = packageURL("追加Finder作品")
        await repository.seed(NovelDocument.newDocument(title: "先行作品"), at: firstURL)
        let queuedDocument = NovelDocument.newDocument(title: "追加作品")
        await repository.seed(queuedDocument, at: queuedURL)
        await repository.pauseLoad(at: firstURL)
        await repository.pauseLoad(at: queuedURL)
        let state = makeState(repository: repository, defaults: makeUserDefaults())

        var initialBootstrapDidReturn = false
        let initialBootstrap = Task { @MainActor in
            await state.bootstrap(opening: firstURL)
            initialBootstrapDidReturn = true
        }
        let firstDidPause = await repository.waitUntilLoadIsPaused(at: firstURL)

        var queuedBootstrapDidReturn = false
        let queuedBootstrap = Task { @MainActor in
            await state.bootstrap(opening: queuedURL)
            queuedBootstrapDidReturn = true
        }
        await allowTasksToRun()
        await repository.resumeLoad(at: firstURL)

        let queuedDidPause = await repository.waitUntilLoadIsPaused(at: queuedURL)
        #expect(firstDidPause)
        #expect(queuedDidPause)
        #expect(!initialBootstrapDidReturn)
        #expect(!queuedBootstrapDidReturn)

        await repository.resumeLoad(at: queuedURL)
        await initialBootstrap.value
        await queuedBootstrap.value

        #expect(initialBootstrapDidReturn)
        #expect(queuedBootstrapDidReturn)
        #expect(state.startupState == .ready)
        #expect(state.document == queuedDocument)
        #expect(state.documentURL == queuedURL.standardizedFileURL)
        #expect(await repository.loadCount == 2)
    }

    @Test("Finder指定URLはrecentより優先する")
    func finderURLTakesPriorityOverRecentDocument() async {
        let repository = BootstrapRepository()
        let defaults = makeUserDefaults()
        let recentURL = packageURL("recent")
        let finderURL = packageURL("Finder")
        await repository.seed(NovelDocument.newDocument(title: "recent"), at: recentURL)
        let finderDocument = NovelDocument.newDocument(title: "Finderから")
        await repository.seed(finderDocument, at: finderURL)
        defaults.set(recentURL.path, forKey: AppPreferenceKey.recentDocumentPath)
        let state = makeState(repository: repository, defaults: defaults)

        await state.bootstrap(opening: finderURL)

        #expect(state.startupState == .ready)
        #expect(state.document == finderDocument)
        #expect(state.documentURL == finderURL.standardizedFileURL)
        #expect(await repository.loadCount == 1)
        #expect(defaults.string(forKey: AppPreferenceKey.recentDocumentPath) == finderURL.path)
    }

    @Test("Recoveryからの明示的新規作成だけがrecentを切り替える")
    func explicitNewDocumentFromRecoveryChangesRecentAfterSave() async {
        let repository = BootstrapRepository(loadFails: true)
        let defaults = makeUserDefaults()
        let brokenURL = packageURL("壊れた原稿")
        defaults.set(brokenURL.path, forKey: AppPreferenceKey.recentDocumentPath)
        let state = makeState(repository: repository, defaults: defaults)
        await state.bootstrap()
        #expect(await state.openRecentDocument(expectedSession: state.documentSessionToken) == false)

        #expect(await state.createNewDocument(expectedSession: state.documentSessionToken))

        #expect(state.startupState == .ready)
        #expect(state.documentURL != brokenURL.standardizedFileURL)
        #expect(defaults.string(forKey: AppPreferenceKey.recentDocumentPath) == state.documentURL.path)
        #expect(await repository.saveCount == 1)
    }
}

extension AppStateBootstrapTests {
    @Test("作品選択画面から終了してもplaceholderを保存しない")
    func terminationFromDocumentSelectionDoesNotSave() async {
        let repository = BootstrapRepository()
        let state = makeState(repository: repository, defaults: makeUserDefaults())

        await state.bootstrap()

        #expect(documentSelectionContext(in: state) != nil)
        #expect(await state.saveBeforeTermination())
        #expect(await repository.loadCount == 0)
        #expect(await repository.saveCount == 0)
    }

    @Test("作品選択画面は実NSHostingViewで副作用なくlayoutできる")
    func documentSelectionViewLaysOutWithoutIO() async throws {
        let repository = BootstrapRepository()
        let defaults = makeUserDefaults()
        let recentURL = packageURL("画面確認作品")
        defaults.set(recentURL.path, forKey: AppPreferenceKey.recentDocumentPath)
        let state = makeState(repository: repository, defaults: defaults)
        await state.bootstrap()
        let context = try #require(documentSelectionContext(in: state))
        let presenter = DocumentPanelPresenter(appState: state)
        let host = NSHostingView(rootView: StartupDocumentSelectionView(context: context)
            .environment(state)
            .environment(presenter))

        host.frame = NSRect(x: 0, y: 0, width: 960, height: 640)
        host.layoutSubtreeIfNeeded()

        #expect(host.fittingSize.width >= 720)
        #expect(host.fittingSize.height >= 480)
        #expect(host.isHidden == false)
        #expect(state.startupState == .documentSelection(context))
        #expect(await repository.loadCount == 0)
        #expect(await repository.saveCount == 0)
    }

    private func makeState(repository: BootstrapRepository, defaults: UserDefaults) -> AppState {
        AppState(
            dependencies: AppDependencies(
                repository: repository,
                userDefaults: defaults,
                fileManager: .default
            )
        )
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "FUMINIWABootstrapTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func documentSelectionContext(in state: AppState) -> StartupDocumentSelectionContext? {
        guard case let .documentSelection(context) = state.startupState else { return nil }
        return context
    }

    private func allowTasksToRun(iterations: Int = 20) async {
        for _ in 0 ..< iterations {
            await Task.yield()
        }
    }

    private func packageURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWABootstrapTests")
            .appendingPathComponent("\(name).novelpkg")
    }
}

private actor BootstrapRepository: DocumentRepository {
    private var documents: [String: NovelDocument] = [:]
    private var loadFails: Bool
    private var saveFails: Bool
    private var loadPathsToPause: Set<String> = []
    private var pausedLoadContinuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var releasedLoadPaths: Set<String> = []
    private(set) var loadCount = 0
    private(set) var saveCount = 0

    init(loadFails: Bool = false, saveFails: Bool = false) {
        self.loadFails = loadFails
        self.saveFails = saveFails
    }

    func load(from url: URL) async throws -> NovelDocument {
        let path = url.standardizedFileURL.path
        loadCount += 1
        if loadPathsToPause.remove(path) != nil,
           releasedLoadPaths.remove(path) == nil {
            await withCheckedContinuation { continuation in
                pausedLoadContinuations[path] = continuation
            }
        }
        guard !loadFails, let document = documents[path] else {
            throw BootstrapRepositoryError.loadFailed
        }
        return document
    }

    func save(_ document: NovelDocument, to url: URL) async throws {
        saveCount += 1
        guard !saveFails else { throw BootstrapRepositoryError.saveFailed }
        documents[url.standardizedFileURL.path] = document
    }

    func seed(_ document: NovelDocument, at url: URL) {
        documents[url.standardizedFileURL.path] = document
    }

    func setLoadFailure(_ shouldFail: Bool) {
        loadFails = shouldFail
    }

    func pauseLoad(at url: URL) {
        loadPathsToPause.insert(url.standardizedFileURL.path)
    }

    func waitUntilLoadIsPaused(
        at url: URL,
        timeout: Duration = .seconds(2)
    ) async -> Bool {
        let path = url.standardizedFileURL.path
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if pausedLoadContinuations[path] != nil {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return pausedLoadContinuations[path] != nil
    }

    func resumeLoad(at url: URL) {
        let path = url.standardizedFileURL.path
        if let continuation = pausedLoadContinuations.removeValue(forKey: path) {
            continuation.resume()
        } else {
            // A timeout path must not leave a later-arriving load suspended forever.
            releasedLoadPaths.insert(path)
        }
    }
}

private enum BootstrapRepositoryError: Error {
    case loadFailed
    case saveFailed
}
