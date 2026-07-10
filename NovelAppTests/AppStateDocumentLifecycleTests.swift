import Foundation
import NovelCore
@testable import NovelWriter
import Testing

@MainActor
struct AppStateDocumentLifecycleTests {
    @Test("開く成功時は現在作品を保存してから全状態を切り替える")
    func openDocumentCommitsAllStateAfterSavingCurrentDocument() async {
        let repository = LifecycleRepository()
        let defaults = makeUserDefaults()
        let sourceURL = packageURL("Source")
        let targetURL = packageURL("Target")
        let source = makeDocument(title: "元作品", chapterTitles: ["元1", "元2"])
        let target = makeDocument(title: "次作品", chapterTitles: ["次1", "次2"])
        let targetAttachments = [NovelCore.Attachment(fileName: "次の資料.txt", byteCount: 12)]
        await repository.seed(
            source,
            at: sourceURL,
            attachments: [NovelCore.Attachment(fileName: "元の資料.txt", byteCount: 8)]
        )
        await repository.seed(target, at: targetURL, attachments: targetAttachments)
        let state = makeState(repository: repository, defaults: defaults)

        #expect(await state.openDocument(at: sourceURL))
        state.selectChapter(source.chapters[1].id)
        state.updateSelectedChapterContent("切り替え直前の編集")

        #expect(await state.openDocument(at: targetURL))
        #expect(state.document == target)
        #expect(state.documentURL == targetURL.standardizedFileURL)
        #expect(state.selection == target.chapters.first?.id)
        #expect(state.selectedChapterID == target.chapters.first?.id)
        #expect(state.selectedEpisodeID == target.chapters.first?.episodes.first?.id)
        #expect(state.selectedCharacterID == target.characters.first?.id)
        #expect(state.selectedPlotCardID == target.plotCards.first?.id)
        #expect(state.selectedFlagID == target.flags.first?.id)
        #expect(state.attachments == targetAttachments)
        #expect(recentDocumentPath(in: defaults) == targetURL.standardizedFileURL.path)

        let savedSource = await repository.document(at: sourceURL)
        #expect(savedSource?.chapters[1].content == "切り替え直前の編集")
    }

    @Test("現在作品の保存失敗時は読み込み済み候補へ切り替えない")
    func openDocumentKeepsCurrentStateWhenSavingCurrentDocumentFails() async {
        let repository = LifecycleRepository()
        let defaults = makeUserDefaults()
        let sourceURL = packageURL("SaveFailureSource")
        let targetURL = packageURL("SaveFailureTarget")
        let source = makeDocument(title: "保存失敗元", chapterTitles: ["元1", "元2"])
        let target = makeDocument(title: "切替候補", chapterTitles: ["候補1"])
        let sourceAttachments = [NovelCore.Attachment(fileName: "保持資料.pdf", byteCount: 42)]
        await repository.seed(source, at: sourceURL, attachments: sourceAttachments)
        await repository.seed(target, at: targetURL, attachments: [])
        let state = makeState(repository: repository, defaults: defaults)

        #expect(await state.openDocument(at: sourceURL))
        state.selectChapter(source.chapters[1].id)
        state.updateSelectedChapterContent("未保存の本文")
        await repository.setSaveFailure(true)

        #expect(await state.openDocument(at: targetURL) == false)
        #expect(state.document.title == source.title)
        #expect(state.document.chapters[1].content == "未保存の本文")
        #expect(state.documentURL == sourceURL.standardizedFileURL)
        #expect(state.selection == source.chapters[1].id)
        #expect(state.attachments == sourceAttachments)
        #expect(recentDocumentPath(in: defaults) == sourceURL.standardizedFileURL.path)
    }

    @Test("作品または資料の読み込み失敗時は現在状態を一切変更しない", arguments: [false, true])
    func openDocumentKeepsCurrentStateWhenCandidateLoadFails(attachmentLoadFails: Bool) async {
        let repository = LifecycleRepository()
        let defaults = makeUserDefaults()
        let sourceURL = packageURL("LoadFailureSource-\(attachmentLoadFails)")
        let targetURL = packageURL("LoadFailureTarget-\(attachmentLoadFails)")
        let source = makeDocument(title: "現在作品", chapterTitles: ["第1章", "第2章"])
        let sourceAttachments = [NovelCore.Attachment(fileName: "現在資料.txt", byteCount: 10)]
        await repository.seed(source, at: sourceURL, attachments: sourceAttachments)
        await repository.seed(makeDocument(title: "候補作品", chapterTitles: ["候補"]), at: targetURL, attachments: [])
        let state = makeState(repository: repository, defaults: defaults)

        #expect(await state.openDocument(at: sourceURL))
        state.selectChapter(source.chapters[1].id)
        if attachmentLoadFails {
            await repository.setAttachmentLoadFailure(at: targetURL)
        } else {
            await repository.setDocumentLoadFailure(at: targetURL)
        }

        let beforeDocument = state.document
        let beforeSelection = state.selection
        let beforeAttachments = state.attachments
        #expect(await state.openDocument(at: targetURL) == false)
        #expect(state.document == beforeDocument)
        #expect(state.documentURL == sourceURL.standardizedFileURL)
        #expect(state.selection == beforeSelection)
        #expect(state.attachments == beforeAttachments)
        #expect(recentDocumentPath(in: defaults) == sourceURL.standardizedFileURL.path)
    }

    @Test("新規作品は現在作品の保存と新規パッケージ保存の両方が成功してから切り替える")
    func createNewDocumentIsTransactional() async {
        let repository = LifecycleRepository()
        let defaults = makeUserDefaults()
        let sourceURL = packageURL("NewDocumentSource")
        let source = makeDocument(title: "執筆中", chapterTitles: ["第1章"])
        await repository.seed(source, at: sourceURL, attachments: [])
        let state = makeState(repository: repository, defaults: defaults)

        #expect(await state.openDocument(at: sourceURL))
        state.updateSelectedChapterContent("保存してから新規作成")
        #expect(await state.createNewDocument())
        #expect(state.document.title == "新規作品")
        #expect(state.documentURL != sourceURL.standardizedFileURL)
        #expect(state.selection == state.document.chapters.first?.id)
        #expect(state.attachments.isEmpty)
        #expect(recentDocumentPath(in: defaults) == state.documentURL.path)
        #expect(await repository.document(at: sourceURL)?.chapters[0].content == "保存してから新規作成")
    }

    @Test("新規作品の保存失敗時は現在作品と資料を維持する")
    func createNewDocumentKeepsCurrentStateWhenNewPackageSaveFails() async {
        let repository = LifecycleRepository()
        let defaults = makeUserDefaults()
        let sourceURL = packageURL("NewDocumentFailureSource")
        let source = makeDocument(title: "維持する作品", chapterTitles: ["第1章", "第2章"])
        let sourceAttachments = [NovelCore.Attachment(fileName: "維持資料.txt", byteCount: 16)]
        await repository.seed(source, at: sourceURL, attachments: sourceAttachments)
        let state = makeState(repository: repository, defaults: defaults)

        #expect(await state.openDocument(at: sourceURL))
        state.selectChapter(source.chapters[1].id)
        await repository.setSaveFailure(true)

        #expect(await state.createNewDocument() == false)
        #expect(state.document == source)
        #expect(state.documentURL == sourceURL.standardizedFileURL)
        #expect(state.selection == source.chapters[1].id)
        #expect(state.attachments == sourceAttachments)
        #expect(recentDocumentPath(in: defaults) == sourceURL.standardizedFileURL.path)
    }

    @Test("別名保存はコピー成功後だけURLを変え、資料と選択を維持する")
    func saveAsSwitchesURLOnlyAfterSuccessfulCopy() async {
        let repository = LifecycleRepository()
        let defaults = makeUserDefaults()
        let sourceURL = packageURL("SaveAsSource")
        let destinationURL = packageURL("SaveAsDestination")
        let document = makeDocument(title: "別名保存", chapterTitles: ["第1章", "第2章"])
        let attachments = [NovelCore.Attachment(fileName: "設定資料.md", byteCount: 24)]
        await repository.seed(document, at: sourceURL, attachments: attachments)
        let state = makeState(repository: repository, defaults: defaults)

        #expect(await state.openDocument(at: sourceURL))
        state.selectChapter(document.chapters[1].id)
        await repository.setCopyFailure(true)
        #expect(await state.saveDocument(as: destinationURL) == false)
        #expect(state.documentURL == sourceURL.standardizedFileURL)
        #expect(recentDocumentPath(in: defaults) == sourceURL.standardizedFileURL.path)

        await repository.setCopyFailure(false)
        #expect(await state.saveDocument(as: destinationURL))
        #expect(state.documentURL == destinationURL.standardizedFileURL)
        #expect(state.selection == document.chapters[1].id)
        #expect(state.selectedEpisodeID == document.chapters[1].episodes.first?.id)
        #expect(state.attachments == attachments)
        #expect(recentDocumentPath(in: defaults) == destinationURL.standardizedFileURL.path)
        #expect(await repository.document(at: destinationURL) == state.document)
        #expect(await repository.attachments(at: destinationURL) == attachments)
    }

    @Test("スナップショット復元は現在状態を退避してから本文と資料を戻し、URLは変えない")
    func restoreSnapshotBacksUpCurrentStateThenRestoresContent() async throws {
        let repository = LifecycleRepository()
        let defaults = makeUserDefaults()
        let packageURL = packageURL("RestoreSource")
        let original = makeDocument(title: "復元元", chapterTitles: ["第1章", "第2章"])
        let originalAttachments = [NovelCore.Attachment(fileName: "旧資料.txt", byteCount: 8)]
        await repository.seed(original, at: packageURL, attachments: originalAttachments)
        let state = makeState(repository: repository, defaults: defaults)

        #expect(await state.openDocument(at: packageURL))
        let snapshotURL = try #require(await state.createSnapshot())

        state.selectChapter(original.chapters[1].id)
        state.updateSelectedChapterContent("復元前の編集")
        let newerAttachments = [NovelCore.Attachment(fileName: "新資料.txt", byteCount: 16)]
        await repository.setAttachments(newerAttachments, at: packageURL)
        #expect(await state.saveBeforeTermination())

        #expect(await state.restoreSnapshot(at: snapshotURL))
        #expect(state.documentURL == packageURL.standardizedFileURL)
        #expect(state.document.chapters[0].content == original.chapters[0].content)
        #expect(state.document.chapters[1].content == original.chapters[1].content)
        #expect(state.selection == original.chapters.first?.id)
        #expect(state.selectedEpisodeID == original.chapters.first?.episodes.first?.id)
        #expect(state.attachments == originalAttachments)
        #expect(recentDocumentPath(in: defaults) == packageURL.standardizedFileURL.path)

        let snapshots = await state.listSnapshots()
        #expect(snapshots.count == 2)
        #expect(await repository.document(at: packageURL)?.chapters[1].content == original.chapters[1].content)
        #expect(await repository.attachments(at: packageURL) == originalAttachments)

        let backup = try #require(snapshots.first { $0.url != snapshotURL })
        #expect(await repository.document(at: backup.url)?.chapters[1].content == "復元前の編集")
    }

    @Test("スナップショット復元は退避または書き戻し失敗時に現在状態を維持する", arguments: [false, true])
    func restoreSnapshotKeepsCurrentStateOnFailure(restoreFails: Bool) async throws {
        let repository = LifecycleRepository()
        let defaults = makeUserDefaults()
        let packageURL = packageURL("RestoreFailure-\(restoreFails)")
        let original = makeDocument(title: "失敗時維持", chapterTitles: ["第1章", "第2章"])
        let attachments = [NovelCore.Attachment(fileName: "維持資料.txt", byteCount: 4)]
        await repository.seed(original, at: packageURL, attachments: attachments)
        let state = makeState(repository: repository, defaults: defaults)

        #expect(await state.openDocument(at: packageURL))
        let snapshotURL = try #require(await state.createSnapshot())

        state.selectChapter(original.chapters[1].id)
        state.updateSelectedChapterContent("失敗しても残る本文")
        #expect(await state.saveBeforeTermination())

        if restoreFails {
            await repository.setRestoreFailure(true)
        } else {
            await repository.setSnapshotFailure(true)
        }

        #expect(await state.restoreSnapshot(at: snapshotURL) == false)
        #expect(state.document.chapters[1].content == "失敗しても残る本文")
        #expect(state.documentURL == packageURL.standardizedFileURL)
        #expect(state.selection == original.chapters[1].id)
        #expect(state.attachments == attachments)
        #expect(await repository.document(at: packageURL)?.chapters[1].content == "失敗しても残る本文")
    }

    private func makeState(repository: LifecycleRepository, defaults: UserDefaults) -> AppState {
        AppState(
            dependencies: AppDependencies(
                repository: repository,
                userDefaults: defaults,
                fileManager: .default
            )
        )
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "NovelWriterLifecycleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func recentDocumentPath(in defaults: UserDefaults) -> String? {
        defaults.string(forKey: "dev.serikayuzuki.NovelWriter.recentDocumentPath")
    }

    private func packageURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NovelWriterLifecycleTests", isDirectory: true)
            .appendingPathComponent("\(name).novelpkg", isDirectory: true)
    }

    private func makeDocument(title: String, chapterTitles: [String]) -> NovelDocument {
        let chapters = chapterTitles.map { Chapter(title: $0, content: "\($0)本文") }
        return NovelDocument(
            title: title,
            chapters: chapters,
            characters: [NovelCore.Character(name: "人物")],
            plotCards: [PlotCard(title: "カード", chapterID: chapters.first?.id)],
            flags: [Flag(title: "伏線", plantedChapterID: chapters.first?.id)]
        )
    }

    @Test("話の選択は章と独立し、章へ戻ると最後の話を復元する")
    func episodeSelectionIsRememberedPerChapter() async {
        let repository = LifecycleRepository()
        let defaults = makeUserDefaults()
        let first = Episode(title: "第一話", content: "A")
        let second = Episode(title: "第二話", content: "B")
        let firstChapter = Chapter(title: "第1章", episodes: [first, second])
        let emptyChapter = Chapter(title: "第2章", episodes: [])
        let document = NovelDocument(title: "話選択", chapters: [firstChapter, emptyChapter])
        let url = packageURL("EpisodeSelection")
        await repository.seed(document, at: url, attachments: [])
        let state = makeState(repository: repository, defaults: defaults)

        #expect(await state.openDocument(at: url))
        #expect(state.selectedChapterID == firstChapter.id)
        #expect(state.selectedEpisodeID == first.id)

        state.selectEpisode(second.id)
        #expect(state.selectedChapterID == firstChapter.id)
        #expect(state.selectedEpisodeID == second.id)

        state.selectChapter(emptyChapter.id)
        #expect(state.selectedChapterID == emptyChapter.id)
        #expect(state.selectedEpisodeID == nil)

        state.selectChapter(firstChapter.id)
        #expect(state.selectedEpisodeID == second.id)
    }

    @Test("話の追加・編集・章間移動・削除で選択を有効な話へ保つ")
    func episodeOperationsUpdateSelection() async throws {
        let repository = LifecycleRepository()
        let defaults = makeUserDefaults()
        let firstChapter = Chapter(title: "第1章", episodes: [])
        let secondChapter = Chapter(title: "第2章", episodes: [])
        let document = NovelDocument(title: "話操作", chapters: [firstChapter, secondChapter])
        let url = packageURL("EpisodeOperations")
        await repository.seed(document, at: url, attachments: [])
        let state = makeState(repository: repository, defaults: defaults)

        #expect(await state.openDocument(at: url))
        let firstEpisodeID = try #require(state.addEpisode(to: firstChapter.id, title: "第一話"))
        state.updateSelectedEpisodeContent("本文")
        state.updateSelectedEpisodeMemo("メモ")
        #expect(state.selectedEpisode?.content == "本文")
        #expect(state.selectedEpisode?.memo == "メモ")

        state.moveEpisode(id: firstEpisodeID, from: firstChapter.id, to: secondChapter.id)
        #expect(state.selectedChapterID == secondChapter.id)
        #expect(state.selectedEpisodeID == firstEpisodeID)

        state.deleteEpisode(id: firstEpisodeID, from: secondChapter.id)
        #expect(state.selectedChapterID == secondChapter.id)
        #expect(state.selectedEpisodeID == nil)
    }
}

private actor LifecycleRepository: DocumentCopyingRepository, SnapshottingDocumentRepository, AttachmentManaging {
    private var documents: [String: NovelDocument] = [:]
    private var storedAttachments: [String: [NovelCore.Attachment]] = [:]
    private var snapshotsByPackage: [String: [DocumentSnapshotInfo]] = [:]
    private var documentLoadFailurePaths: Set<String> = []
    private var attachmentLoadFailurePaths: Set<String> = []
    private var shouldFailSave = false
    private var shouldFailCopy = false
    private var shouldFailSnapshot = false
    private var shouldFailRestore = false

    func seed(_ document: NovelDocument, at url: URL, attachments: [NovelCore.Attachment]) {
        documents[key(url)] = document
        storedAttachments[key(url)] = attachments
        snapshotsByPackage[key(url)] = []
    }

    func setDocumentLoadFailure(at url: URL) {
        documentLoadFailurePaths.insert(key(url))
    }

    func setAttachmentLoadFailure(at url: URL) {
        attachmentLoadFailurePaths.insert(key(url))
    }

    func setSaveFailure(_ value: Bool) {
        shouldFailSave = value
    }

    func setCopyFailure(_ value: Bool) {
        shouldFailCopy = value
    }

    func setSnapshotFailure(_ value: Bool) {
        shouldFailSnapshot = value
    }

    func setRestoreFailure(_ value: Bool) {
        shouldFailRestore = value
    }

    func setAttachments(_ attachments: [NovelCore.Attachment], at url: URL) {
        storedAttachments[key(url)] = attachments
    }

    func document(at url: URL) -> NovelDocument? {
        documents[key(url)]
    }

    func attachments(at url: URL) -> [NovelCore.Attachment] {
        storedAttachments[key(url)] ?? []
    }

    func load(from url: URL) async throws -> NovelDocument {
        guard !documentLoadFailurePaths.contains(key(url)), let document = documents[key(url)] else {
            throw LifecycleRepositoryError.loadFailed
        }
        return document
    }

    func save(_ doc: NovelDocument, to url: URL) async throws {
        guard !shouldFailSave else { throw LifecycleRepositoryError.saveFailed }
        documents[key(url)] = doc
        storedAttachments[key(url)] = storedAttachments[key(url)] ?? []
    }

    func saveCopy(_ doc: NovelDocument, from sourceURL: URL, to destinationURL: URL) async throws {
        guard !shouldFailCopy else { throw LifecycleRepositoryError.saveFailed }
        documents[key(destinationURL)] = doc
        storedAttachments[key(destinationURL)] = storedAttachments[key(sourceURL)] ?? []
        snapshotsByPackage[key(destinationURL)] = snapshotsByPackage[key(sourceURL)] ?? []
    }

    func saveSnapshot(_ doc: NovelDocument, to url: URL) async throws -> URL {
        guard !shouldFailSnapshot else { throw LifecycleRepositoryError.saveFailed }
        let snapshotURL = url
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).novelpkg", isDirectory: true)
        documents[key(snapshotURL)] = doc
        storedAttachments[key(snapshotURL)] = storedAttachments[key(url)] ?? []
        let createdAt = Date()
        let info = DocumentSnapshotInfo(
            url: snapshotURL,
            createdAt: createdAt,
            displayName: "snapshot-\(createdAt.timeIntervalSince1970)"
        )
        var listed = snapshotsByPackage[key(url)] ?? []
        listed.insert(info, at: 0)
        snapshotsByPackage[key(url)] = listed
        return snapshotURL
    }

    func listSnapshots(in url: URL) async throws -> [DocumentSnapshotInfo] {
        snapshotsByPackage[key(url)] ?? []
    }

    func restoreSnapshot(from snapshotURL: URL, into packageURL: URL) async throws {
        guard !shouldFailRestore else { throw LifecycleRepositoryError.saveFailed }
        guard let document = documents[key(snapshotURL)] else {
            throw LifecycleRepositoryError.loadFailed
        }
        documents[key(packageURL)] = document
        storedAttachments[key(packageURL)] = storedAttachments[key(snapshotURL)] ?? []
    }

    func listAttachments(in packageURL: URL) async throws -> [NovelCore.Attachment] {
        guard !attachmentLoadFailurePaths.contains(key(packageURL)) else {
            throw LifecycleRepositoryError.loadFailed
        }
        return storedAttachments[key(packageURL)] ?? []
    }

    func addAttachment(from _: URL, to _: URL) async throws -> NovelCore.Attachment {
        throw LifecycleRepositoryError.unsupported
    }

    func deleteAttachment(named _: String, from _: URL) async throws {
        throw LifecycleRepositoryError.unsupported
    }

    nonisolated func attachmentURL(named fileName: String, in packageURL: URL) -> URL {
        packageURL.appendingPathComponent(fileName)
    }

    private func key(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}

private enum LifecycleRepositoryError: Error {
    case loadFailed
    case saveFailed
    case unsupported
}
