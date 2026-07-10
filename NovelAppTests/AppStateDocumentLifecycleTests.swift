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
        #expect(state.attachments == attachments)
        #expect(recentDocumentPath(in: defaults) == destinationURL.standardizedFileURL.path)
        #expect(await repository.document(at: destinationURL) == state.document)
        #expect(await repository.attachments(at: destinationURL) == attachments)
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
}

private actor LifecycleRepository: DocumentCopyingRepository, AttachmentManaging {
    private var documents: [String: NovelDocument] = [:]
    private var storedAttachments: [String: [NovelCore.Attachment]] = [:]
    private var documentLoadFailurePaths: Set<String> = []
    private var attachmentLoadFailurePaths: Set<String> = []
    private var shouldFailSave = false
    private var shouldFailCopy = false

    func seed(_ document: NovelDocument, at url: URL, attachments: [NovelCore.Attachment]) {
        documents[key(url)] = document
        storedAttachments[key(url)] = attachments
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
