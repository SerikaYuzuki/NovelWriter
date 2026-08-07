import Foundation
@testable import FUMINIWA
import NovelCore
import Testing

@MainActor
struct AppStateBootstrapTests {
    @Test("起動直後は編集可能なreadyではない")
    func startsInLoadingState() {
        let state = makeState(repository: BootstrapRepository(), defaults: makeUserDefaults())

        #expect(state.startupState == .loading)
        #expect(!state.startupState.isReady)
    }

    @Test("前回作品の読込成功後だけreadyにする")
    func recentDocumentLoadBecomesReadyWithoutSaving() async {
        let repository = BootstrapRepository()
        let defaults = makeUserDefaults()
        let url = packageURL("前回作品")
        let document = NovelDocument.newDocument(title: "続きから")
        await repository.seed(document, at: url)
        defaults.set(url.path, forKey: AppPreferenceKey.recentDocumentPath)
        let state = makeState(repository: repository, defaults: defaults)

        await state.bootstrap()

        #expect(state.startupState == .ready)
        #expect(state.document == document)
        #expect(state.documentURL.path == url.standardizedFileURL.path)
        #expect(await repository.loadCount == 1)
        #expect(await repository.saveCount == 0)
        #expect(defaults.string(forKey: AppPreferenceKey.recentDocumentPath) == url.path)
    }

    @Test("前回作品を開けないときは保存もrecent更新もせずRecoveryで止まる")
    func recentDocumentFailureFailsClosed() async {
        let repository = BootstrapRepository(loadFails: true)
        let defaults = makeUserDefaults()
        let url = packageURL("開けない作品")
        defaults.set(url.path, forKey: AppPreferenceKey.recentDocumentPath)
        let state = makeState(repository: repository, defaults: defaults)

        await state.bootstrap()

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
        await repository.setLoadFailure(false)
        await state.retryStartup()

        #expect(state.startupState == .ready)
        #expect(state.document == document)
        #expect(state.documentURL.path == url.standardizedFileURL.path)
        #expect(await repository.loadCount == 2)
        #expect(await repository.saveCount == 0)
    }

    @Test("recentが無い初回起動は保存成功後だけ採用する")
    func initialDocumentIsInstalledAfterSuccessfulSave() async {
        let repository = BootstrapRepository()
        let defaults = makeUserDefaults()
        let state = makeState(repository: repository, defaults: defaults)

        await state.bootstrap()

        #expect(state.startupState == .ready)
        #expect(await repository.saveCount == 1)
        #expect(defaults.string(forKey: AppPreferenceKey.recentDocumentPath) == state.documentURL.path)
        #expect(state.documentURL.deletingLastPathComponent().lastPathComponent == "Drafts")
        #expect(state.documentURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "FUMINIWA")
    }

    @Test("初回新規保存の失敗はrecentを作らない")
    func initialDocumentSaveFailureEntersRecovery() async {
        let repository = BootstrapRepository(saveFails: true)
        let defaults = makeUserDefaults()
        let state = makeState(repository: repository, defaults: defaults)

        await state.bootstrap()

        guard case let .recovery(context) = state.startupState else {
            Issue.record("Recoveryへ移行しませんでした")
            return
        }
        #expect(context.reason == .cannotCreateDocument)
        #expect(context.source == .initialDocument)
        #expect(defaults.string(forKey: AppPreferenceKey.recentDocumentPath) == nil)
        #expect(await repository.saveCount == 1)
    }

    @Test("bootstrapを二度呼んでも作品を二重に作らない")
    func bootstrapIsIdempotent() async {
        let repository = BootstrapRepository()
        let state = makeState(repository: repository, defaults: makeUserDefaults())

        await state.bootstrap()
        await state.bootstrap()

        #expect(await repository.saveCount == 1)
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

        #expect(await state.createNewDocument())

        #expect(state.startupState == .ready)
        #expect(state.documentURL != brokenURL.standardizedFileURL)
        #expect(defaults.string(forKey: AppPreferenceKey.recentDocumentPath) == state.documentURL.path)
        #expect(await repository.saveCount == 1)
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
    private(set) var loadCount = 0
    private(set) var saveCount = 0

    init(loadFails: Bool = false, saveFails: Bool = false) {
        self.loadFails = loadFails
        self.saveFails = saveFails
    }

    func load(from url: URL) async throws -> NovelDocument {
        loadCount += 1
        guard !loadFails, let document = documents[url.standardizedFileURL.path] else {
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
}

private enum BootstrapRepositoryError: Error {
    case loadFailed
    case saveFailed
}
