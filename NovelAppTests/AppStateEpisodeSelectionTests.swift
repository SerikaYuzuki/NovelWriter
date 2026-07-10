import Foundation
import NovelCore
@testable import NovelWriter
import Testing

@MainActor
struct AppStateEpisodeSelectionTests {
    @Test("新規状態は最初の章と本文話を選択する")
    func newStateSelectsFirstEpisode() {
        let state = makeState()

        #expect(state.selectedChapterID == state.document.chapters.first?.id)
        #expect(state.selectedEpisodeID == state.document.chapters.first?.episodes.first?.id)
    }

    @Test("タイトル省略の話追加は第N話になる")
    func addEpisodeWithoutTitleUsesNumberedDefault() throws {
        let state = makeState()
        let chapterID = try #require(state.selectedChapterID)
        #expect(state.document.chapters[0].episodes.count == 1)

        state.addEpisode(to: chapterID)
        #expect(state.selectedEpisode?.title == "第2話")
        #expect(state.document.chapters[0].episodes.map(\.title) == ["本文", "第2話"])
    }

    @Test("話の追加・選択・本文メモ更新は話単位で行う")
    func episodeOperationsUpdateSelectedEpisode() throws {
        let state = makeState()
        let chapterID = try #require(state.selectedChapterID)
        let firstEpisodeID = try #require(state.selectedEpisodeID)

        state.addEpisode(to: chapterID, title: "第2話")
        let secondEpisodeID = try #require(state.selectedEpisodeID)
        #expect(secondEpisodeID != firstEpisodeID)
        #expect(state.selectedEpisode?.title == "第2話")

        state.updateSelectedEpisodeContent("第2話本文")
        state.updateSelectedEpisodeMemo("第2話メモ")
        #expect(try state.document.episode(#require(secondEpisodeID))?.episode.content == "第2話本文")
        #expect(try state.document.episode(#require(secondEpisodeID))?.episode.memo == "第2話メモ")

        state.selectEpisode(firstEpisodeID, in: chapterID)
        #expect(state.selectedEpisodeID == firstEpisodeID)
        #expect(state.selectedEpisode?.content.isEmpty == true)
    }

    @Test("話削除後は同じ章の隣接話へ選択を移す")
    func deletingSelectedEpisodeFallsBackToNeighbor() throws {
        let state = makeState()
        let chapterID = try #require(state.selectedChapterID)
        state.addEpisode(to: chapterID, title: "第2話")
        let secondEpisodeID = try #require(state.selectedEpisodeID)
        let firstEpisodeID = state.document.chapters[0].episodes[0].id

        #expect(try state.deleteEpisode(id: #require(secondEpisodeID), from: chapterID))
        #expect(state.selectedEpisodeID == firstEpisodeID)
        #expect(state.document.chapters[0].episodes.count == 1)
    }

    @Test("別章へ話を移動すると選択章も追従する")
    func movingSelectedEpisodeAcrossChaptersMovesSelection() throws {
        let state = makeState()
        let sourceChapterID = try #require(state.selectedChapterID)
        let episodeID = try #require(state.selectedEpisodeID)
        state.addChapter()
        let destinationChapterID = try #require(state.selectedChapterID)
        state.selectEpisode(episodeID, in: sourceChapterID)

        #expect(try state.moveEpisode(
            id: episodeID,
            from: sourceChapterID,
            to: #require(destinationChapterID)
        ))
        #expect(state.selectedChapterID == destinationChapterID)
        #expect(state.selectedEpisodeID == episodeID)
    }

    @Test("開く成功時は先頭章と先頭話へ選択を初期化する")
    func openDocumentResetsSelectionToFirstEpisode() async throws {
        let repository = EpisodeLifecycleRepository()
        let defaults = makeUserDefaults()
        let sourceURL = packageURL("OpenSource")
        let targetURL = packageURL("OpenTarget")
        let source = makeDocument(title: "元作品", chapterTitles: ["元1", "元2"], episodesPerChapter: 2)
        let target = makeDocument(title: "次作品", chapterTitles: ["次1", "次2"], episodesPerChapter: 2)
        await repository.seed(source, at: sourceURL, attachments: [])
        await repository.seed(target, at: targetURL, attachments: [])
        let state = makeState(repository: repository, defaults: defaults)

        #expect(await state.openDocument(at: sourceURL))
        let sourceSecondEpisode = try #require(source.chapters[1].episodes[1].id)
        state.selectChapter(source.chapters[1].id)
        state.selectEpisode(sourceSecondEpisode, in: source.chapters[1].id)

        #expect(await state.openDocument(at: targetURL))
        #expect(state.selectedChapterID == target.chapters.first?.id)
        #expect(state.selectedEpisodeID == target.chapters.first?.episodes.first?.id)
    }

    @Test("新規作品は先頭章と先頭話へ選択を初期化する")
    func createNewDocumentResetsSelectionToFirstEpisode() async throws {
        let repository = EpisodeLifecycleRepository()
        let defaults = makeUserDefaults()
        let sourceURL = packageURL("NewDocumentSource")
        let source = makeDocument(title: "執筆中", chapterTitles: ["第1章", "第2章"], episodesPerChapter: 2)
        await repository.seed(source, at: sourceURL, attachments: [])
        let state = makeState(repository: repository, defaults: defaults)

        #expect(await state.openDocument(at: sourceURL))
        let secondEpisode = try #require(source.chapters[1].episodes[1].id)
        state.selectChapter(source.chapters[1].id)
        state.selectEpisode(secondEpisode, in: source.chapters[1].id)

        #expect(await state.createNewDocument())
        #expect(state.selectedChapterID == state.document.chapters.first?.id)
        #expect(state.selectedEpisodeID == state.document.chapters.first?.episodes.first?.id)
    }

    @Test("別名保存成功後も章と話の選択を維持する")
    func saveAsPreservesChapterAndEpisodeSelection() async throws {
        let repository = EpisodeLifecycleRepository()
        let defaults = makeUserDefaults()
        let sourceURL = packageURL("SaveAsSource")
        let destinationURL = packageURL("SaveAsDestination")
        let document = makeDocument(title: "別名保存", chapterTitles: ["第1章", "第2章"], episodesPerChapter: 2)
        await repository.seed(document, at: sourceURL, attachments: [])
        let state = makeState(repository: repository, defaults: defaults)

        #expect(await state.openDocument(at: sourceURL))
        let selectedChapterID = document.chapters[1].id
        let selectedEpisodeID = try #require(document.chapters[1].episodes[1].id)
        state.selectChapter(selectedChapterID)
        state.selectEpisode(selectedEpisodeID, in: selectedChapterID)

        #expect(await state.saveDocument(as: destinationURL))
        #expect(state.documentURL == destinationURL.standardizedFileURL)
        #expect(state.selectedChapterID == selectedChapterID)
        #expect(state.selectedEpisodeID == selectedEpisodeID)
    }

    @Test("スナップショット復元後は先頭章と先頭話へ選択を初期化する")
    func restoreSnapshotResetsSelectionToFirstEpisode() async throws {
        let repository = EpisodeLifecycleRepository()
        let defaults = makeUserDefaults()
        let packageURL = packageURL("RestoreSource")
        let original = makeDocument(title: "復元元", chapterTitles: ["第1章", "第2章"], episodesPerChapter: 2)
        await repository.seed(original, at: packageURL, attachments: [])
        let state = makeState(repository: repository, defaults: defaults)

        #expect(await state.openDocument(at: packageURL))
        let snapshotURL = try #require(await state.createSnapshot())

        let secondEpisode = try #require(original.chapters[1].episodes[1].id)
        state.selectChapter(original.chapters[1].id)
        state.selectEpisode(secondEpisode, in: original.chapters[1].id)
        state.updateSelectedEpisodeContent("復元前の編集")
        #expect(await state.saveBeforeTermination())

        #expect(await state.restoreSnapshot(at: snapshotURL))
        #expect(state.selectedChapterID == original.chapters.first?.id)
        #expect(state.selectedEpisodeID == original.chapters.first?.episodes.first?.id)
    }

    private func makeState(
        repository: EpisodeLifecycleRepository = EpisodeLifecycleRepository(),
        defaults: UserDefaults? = nil
    ) -> AppState {
        AppState(
            dependencies: AppDependencies(
                repository: repository,
                userDefaults: defaults ?? makeUserDefaults(),
                fileManager: .default
            )
        )
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "NovelWriterEpisodeSelection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func packageURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NovelWriterEpisodeSelectionTests", isDirectory: true)
            .appendingPathComponent("\(name).novelpkg", isDirectory: true)
    }

    private func makeDocument(
        title: String,
        chapterTitles: [String],
        episodesPerChapter: Int = 1
    ) -> NovelDocument {
        let chapters = chapterTitles.map { chapterTitle in
            let episodes = (1 ... episodesPerChapter).map { index in
                Episode(title: "第\(index)話", content: "\(chapterTitle)-\(index)本文")
            }
            return Chapter(title: chapterTitle, episodes: episodes)
        }
        return NovelDocument(title: title, chapters: chapters)
    }
}

private actor EpisodeLifecycleRepository: DocumentCopyingRepository, SnapshottingDocumentRepository {
    private var documents: [String: NovelDocument] = [:]
    private var snapshotsByPackage: [String: [DocumentSnapshotInfo]] = [:]

    func seed(_ document: NovelDocument, at url: URL, attachments _: [NovelCore.Attachment]) {
        documents[key(url)] = document
        snapshotsByPackage[key(url)] = []
    }

    func load(from url: URL) async throws -> NovelDocument {
        guard let document = documents[key(url)] else {
            throw EpisodeLifecycleRepositoryError.loadFailed
        }
        return document
    }

    func save(_ doc: NovelDocument, to url: URL) async throws {
        documents[key(url)] = doc
    }

    func saveCopy(_ doc: NovelDocument, from sourceURL: URL, to destinationURL: URL) async throws {
        documents[key(destinationURL)] = doc
        snapshotsByPackage[key(destinationURL)] = snapshotsByPackage[key(sourceURL)] ?? []
    }

    func saveSnapshot(_ doc: NovelDocument, to url: URL) async throws -> URL {
        let snapshotURL = url
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).novelpkg", isDirectory: true)
        documents[key(snapshotURL)] = doc
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
        guard let document = documents[key(snapshotURL)] else {
            throw EpisodeLifecycleRepositoryError.loadFailed
        }
        documents[key(packageURL)] = document
    }

    private func key(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}

private enum EpisodeLifecycleRepositoryError: Error {
    case loadFailed
}
