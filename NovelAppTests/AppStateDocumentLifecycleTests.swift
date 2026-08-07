@testable import EditorKit
import Foundation
@testable import FUMINIWA
import NovelCore
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
        state.updateSelectedEpisodeContent("切り替え直前の編集")

        #expect(await state.openDocument(at: targetURL))
        #expect(state.document == target)
        #expect(state.documentURL == targetURL.standardizedFileURL)
        #expect(state.selectedChapterID == target.chapters.first?.id)
        #expect(state.selectedCharacterID == target.characters.first?.id)
        #expect(state.selectedPlotCardID == target.plotCards.first?.id)
        #expect(state.selectedFlagID == target.flags.first?.id)
        #expect(state.attachments == targetAttachments)
        #expect(recentDocumentPath(in: defaults) == targetURL.standardizedFileURL.path)

        let savedSource = await repository.document(at: sourceURL)
        #expect(savedSource?.chapters[1].episodes.first?.content == "切り替え直前の編集")
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
        state.updateSelectedEpisodeContent("未保存の本文")
        await repository.setSaveFailure(true)

        #expect(await state.openDocument(at: targetURL) == false)
        #expect(state.document.title == source.title)
        #expect(state.document.chapters[1].episodes.first?.content == "未保存の本文")
        #expect(state.documentURL == sourceURL.standardizedFileURL)
        #expect(state.selectedChapterID == source.chapters[1].id)
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
        let beforeSelection = state.selectedChapterID
        let beforeAttachments = state.attachments
        #expect(await state.openDocument(at: targetURL) == false)
        #expect(state.document == beforeDocument)
        #expect(state.documentURL == sourceURL.standardizedFileURL)
        #expect(state.selectedChapterID == beforeSelection)
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
        state.updateSelectedEpisodeContent("保存してから新規作成")
        #expect(await state.createNewDocument())
        #expect(state.document.title == "新規作品")
        #expect(state.documentURL != sourceURL.standardizedFileURL)
        #expect(state.selectedChapterID == state.document.chapters.first?.id)
        #expect(state.attachments.isEmpty)
        #expect(recentDocumentPath(in: defaults) == state.documentURL.path)
        #expect(await repository.document(at: sourceURL)?.chapters[0].episodes.first?.content == "保存してから新規作成")
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
        #expect(state.selectedChapterID == source.chapters[1].id)
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
        #expect(state.selectedChapterID == document.chapters[1].id)
        #expect(state.attachments == attachments)
        #expect(recentDocumentPath(in: defaults) == destinationURL.standardizedFileURL.path)
        #expect(await repository.document(at: destinationURL) == state.document)
        #expect(await repository.attachments(at: destinationURL) == attachments)
    }

    @Test("別名保存中の編集は旧保存先へ戻さず、新保存先へ追記する")
    func saveAsRoutesConcurrentEditsToDestination() async {
        let repository = LifecycleRepository()
        let defaults = makeUserDefaults()
        let sourceURL = packageURL("SaveAsRaceSource")
        let destinationURL = packageURL("SaveAsRaceDestination")
        let source = makeDocument(title: "別名保存競合", chapterTitles: ["第1章"])
        await repository.seed(source, at: sourceURL, attachments: [])
        let state = makeState(repository: repository, defaults: defaults)

        #expect(await state.openDocument(at: sourceURL))
        await repository.pauseNextCopy()

        let saveAsTask = Task { @MainActor in
            await state.saveDocumentResult(as: destinationURL)
        }
        await repository.waitUntilCopyIsPaused()

        state.updateSelectedEpisodeContent("コピー中に追記した本文")
        var manualSaveDidStart = false
        let manualSaveTask = Task { @MainActor in
            manualSaveDidStart = true
            return await state.saveNow()
        }
        while !manualSaveDidStart {
            await Task.yield()
        }

        await repository.resumeCopy()
        #expect(await saveAsTask.value == .saved)
        #expect(await manualSaveTask.value)

        #expect(state.documentURL == destinationURL.standardizedFileURL)
        #expect(await repository.document(at: sourceURL)?.chapters[0].episodes.first?.content == "第1章本文")
        #expect(await repository.document(at: destinationURL)?.chapters[0].episodes.first?.content == "コピー中に追記した本文")
    }

    @Test("別名保存後の追記保存に失敗した場合は失敗を返し、再試行できる")
    func saveAsReportsPostCopySaveFailure() async {
        let repository = LifecycleRepository()
        let defaults = makeUserDefaults()
        let sourceURL = packageURL("SaveAsFlushFailureSource")
        let destinationURL = packageURL("SaveAsFlushFailureDestination")
        let source = makeDocument(title: "別名保存追記失敗", chapterTitles: ["第1章"])
        await repository.seed(source, at: sourceURL, attachments: [])
        let state = makeState(repository: repository, defaults: defaults)

        #expect(await state.openDocument(at: sourceURL))
        await repository.pauseNextCopy()
        let saveAsTask = Task { @MainActor in
            await state.saveDocumentResult(as: destinationURL)
        }
        await repository.waitUntilCopyIsPaused()

        state.updateSelectedEpisodeContent("コピー後に保存できなかった本文")
        await repository.setSaveFailure(true)
        await repository.resumeCopy()

        #expect(await saveAsTask.value == .switchedButLatestEditsFailed)
        #expect(state.documentURL == destinationURL.standardizedFileURL)
        #expect(state.saveState == .failed)
        #expect(recentDocumentPath(in: defaults) == destinationURL.standardizedFileURL.path)
        #expect(state.selectedEpisode?.content == "コピー後に保存できなかった本文")
        #expect(await repository.document(at: destinationURL)?.chapters[0].episodes.first?.content == "第1章本文")

        await repository.setSaveFailure(false)
        #expect(await state.saveNow())
        #expect(await repository.document(at: destinationURL)?.chapters[0].episodes.first?.content == "コピー後に保存できなかった本文")
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
        state.updateSelectedEpisodeContent("復元前の編集")
        let newerAttachments = [NovelCore.Attachment(fileName: "新資料.txt", byteCount: 16)]
        await repository.setAttachments(newerAttachments, at: packageURL)
        #expect(await state.saveNow())

        #expect(await state.restoreSnapshot(at: snapshotURL))
        #expect(state.documentURL == packageURL.standardizedFileURL)
        #expect(state.document.chapters[0].episodes == original.chapters[0].episodes)
        #expect(state.document.chapters[1].episodes == original.chapters[1].episodes)
        #expect(state.selectedChapterID == original.chapters.first?.id)
        #expect(state.attachments == originalAttachments)
        #expect(recentDocumentPath(in: defaults) == packageURL.standardizedFileURL.path)

        let snapshots = await state.listSnapshots()
        #expect(snapshots.count == 2)
        #expect(await repository.document(at: packageURL)?.chapters[1].episodes == original.chapters[1].episodes)
        #expect(await repository.attachments(at: packageURL) == originalAttachments)

        let backup = try #require(snapshots.first { $0.url != snapshotURL })
        #expect(await repository.document(at: backup.url)?.chapters[1].episodes.first?.content == "復元前の編集")
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
        state.updateSelectedEpisodeContent("失敗しても残る本文")
        #expect(await state.saveNow())

        if restoreFails {
            await repository.setRestoreFailure(true)
        } else {
            await repository.setSnapshotFailure(true)
        }

        #expect(await state.restoreSnapshot(at: snapshotURL) == false)
        #expect(state.document.chapters[1].episodes.first?.content == "失敗しても残る本文")
        #expect(state.documentURL == packageURL.standardizedFileURL)
        #expect(state.selectedChapterID == original.chapters[1].id)
        #expect(state.attachments == attachments)
        #expect(await repository.document(at: packageURL)?.chapters[1].episodes.first?.content == "失敗しても残る本文")
    }

    @Test("Finder作品の切替はスナップショット復元を待ち、別作品を上書きしない")
    func finderOpenWaitsForSnapshotRestore() async throws {
        let repository = LifecycleRepository()
        let defaults = makeUserDefaults()
        let sourceURL = packageURL("RestoreRaceSource")
        let finderURL = packageURL("RestoreRaceFinder")
        let source = makeDocument(title: "復元する作品", chapterTitles: ["復元元"])
        let finderDocument = makeDocument(title: "Finder作品", chapterTitles: ["保護対象"])
        let finderAttachments = [NovelCore.Attachment(fileName: "保護資料.txt", byteCount: 32)]
        await repository.seed(source, at: sourceURL, attachments: [])
        await repository.seed(finderDocument, at: finderURL, attachments: finderAttachments)
        let state = makeState(repository: repository, defaults: defaults)

        #expect(await state.openDocument(at: sourceURL))
        let snapshotURL = try #require(await state.createSnapshot())
        state.updateSelectedEpisodeContent("復元前の変更")
        await repository.pauseNextSnapshotSave()

        let restoreTask = Task { @MainActor in
            await state.restoreSnapshot(at: snapshotURL)
        }
        await repository.waitUntilSnapshotSaveIsPaused()

        var finderOpenDidStart = false
        var finderOpenDidReturn = false
        let finderOpenTask = Task { @MainActor in
            finderOpenDidStart = true
            let result = await state.openExternalDocument(at: finderURL)
            finderOpenDidReturn = true
            return result
        }
        while !finderOpenDidStart {
            await Task.yield()
        }

        #expect(!finderOpenDidReturn)
        #expect(state.documentURL == sourceURL.standardizedFileURL)

        await repository.resumeSnapshotSave()
        #expect(await restoreTask.value)
        #expect(await finderOpenTask.value)

        #expect(finderOpenDidReturn)
        #expect(state.document == finderDocument)
        #expect(state.documentURL == finderURL.standardizedFileURL)
        #expect(state.attachments == finderAttachments)
        #expect(await repository.document(at: finderURL) == finderDocument)
        #expect(await repository.attachments(at: finderURL) == finderAttachments)
        #expect(await repository.restoreDestinations() == [sourceURL.standardizedFileURL.path])
    }

    @Test("作品切替の後ろで待った旧作品の復元要求は破棄し、新作品へ適用しない")
    func staleSnapshotRestoreIsRejectedAfterFinderOpen() async throws {
        let repository = LifecycleRepository()
        let defaults = makeUserDefaults()
        let sourceURL = packageURL("StaleRestoreSource")
        let finderURL = packageURL("StaleRestoreFinder")
        let source = makeDocument(title: "旧作品", chapterTitles: ["旧章"])
        let finderDocument = makeDocument(title: "新作品", chapterTitles: ["保護章"])
        let finderAttachments = [NovelCore.Attachment(fileName: "消してはいけない資料.txt", byteCount: 64)]
        await repository.seed(source, at: sourceURL, attachments: [])
        await repository.seed(finderDocument, at: finderURL, attachments: finderAttachments)
        let state = makeState(repository: repository, defaults: defaults)

        #expect(await state.openDocument(at: sourceURL))
        let snapshotURL = try #require(await state.createSnapshot())
        let sourceSession = state.documentSessionToken
        await repository.pauseNextLoad(at: finderURL)

        let finderOpenTask = Task { @MainActor in
            await state.openExternalDocument(at: finderURL)
        }
        await repository.waitUntilLoadIsPaused()

        var restoreDidStart = false
        let restoreTask = Task { @MainActor in
            restoreDidStart = true
            return await state.restoreSnapshot(
                at: snapshotURL,
                expectedSession: sourceSession
            )
        }
        while !restoreDidStart {
            await Task.yield()
        }

        await repository.resumeLoad()
        #expect(await finderOpenTask.value)
        #expect(await restoreTask.value == false)

        #expect(state.document == finderDocument)
        #expect(state.documentURL == finderURL.standardizedFileURL)
        #expect(state.attachments == finderAttachments)
        #expect(await repository.document(at: finderURL) == finderDocument)
        #expect(await repository.attachments(at: finderURL) == finderAttachments)
        #expect(await repository.restoreDestinations().isEmpty)
    }

    @Test("古いスナップショット一覧項目は新しい作品の復元確認に使わない")
    func snapshotPresenterRejectsItemStampedForPreviousDocument() async throws {
        let repository = LifecycleRepository()
        let defaults = makeUserDefaults()
        let sourceURL = packageURL("PresenterSnapshotSource")
        let finderURL = packageURL("PresenterSnapshotFinder")
        await repository.seed(
            makeDocument(title: "一覧元", chapterTitles: ["元章"]),
            at: sourceURL,
            attachments: []
        )
        let finderDocument = makeDocument(title: "切替先", chapterTitles: ["先章"])
        await repository.seed(finderDocument, at: finderURL, attachments: [])
        let state = makeState(repository: repository, defaults: defaults)
        let presenter = SnapshotMenuPresenter(appState: state)

        #expect(await state.openDocument(at: sourceURL))
        _ = try #require(await state.createSnapshot())
        await presenter.refresh()
        let oldItem = try #require(presenter.snapshots.first)

        #expect(await state.openDocument(at: finderURL))
        await presenter.refresh()
        presenter.requestRestore(oldItem)

        #expect(presenter.snapshotPendingRestore == nil)
        #expect(presenter.restoreErrorMessage != nil)
        #expect(state.document == finderDocument)
        #expect(await repository.restoreDestinations().isEmpty)
    }

    @Test("旧作品で開いた削除確認は同じIDを持つ複製作品へ適用しない")
    func staleDeletionRequestsAreRejectedAfterDocumentSwitch() async {
        let repository = LifecycleRepository()
        let defaults = makeUserDefaults()
        let sourceURL = packageURL("StaleDeletionSource")
        let copiedURL = packageURL("StaleDeletionCopy")
        var sharedDocument = makeDocument(title: "複製元", chapterTitles: ["第1章", "第2章"])
        sharedDocument.worldNotes = [WorldNote(title: "世界観")]
        await repository.seed(sharedDocument, at: sourceURL, attachments: [])
        await repository.seed(sharedDocument, at: copiedURL, attachments: [])
        let state = makeState(repository: repository, defaults: defaults)

        #expect(await state.openDocument(at: sourceURL))
        let staleSession = state.documentSessionToken
        let chapter = sharedDocument.chapters[0]
        let episode = chapter.episodes[0]
        let character = sharedDocument.characters[0]
        let plotCard = sharedDocument.plotCards[0]
        let flag = sharedDocument.flags[0]
        let worldNote = sharedDocument.worldNotes[0]

        #expect(await state.openDocument(at: copiedURL))
        #expect(!state.deleteChapter(id: chapter.id, expectedSession: staleSession))
        #expect(!state.deleteEpisode(id: episode.id, from: chapter.id, expectedSession: staleSession))
        #expect(!state.deleteCharacter(id: character.id, expectedSession: staleSession))
        #expect(!state.deletePlotCard(id: plotCard.id, expectedSession: staleSession))
        #expect(!state.deleteFlag(id: flag.id, expectedSession: staleSession))
        #expect(!state.deleteWorldNote(id: worldNote.id, expectedSession: staleSession))
        #expect(state.document == sharedDocument)
    }

    @Test("同じ本文IDを持つ複製作品でもEditorを再読込し、旧callbackを拒否する")
    func clonedDocumentEditorIdentityIncludesSession() async {
        let repository = LifecycleRepository()
        let defaults = makeUserDefaults()
        let sourceURL = packageURL("EditorSessionSource")
        let copiedURL = packageURL("EditorSessionCopy")
        var source = makeDocument(title: "複製元", chapterTitles: ["第1章"])
        source.worldNotes = [WorldNote(title: "世界観", content: "元ノート本文")]
        var copied = source
        copied.title = "複製先"
        copied.chapters[0].episodes[0].content = "複製先の本文"
        copied.worldNotes[0].content = "複製先のノート本文"
        await repository.seed(source, at: sourceURL, attachments: [])
        await repository.seed(copied, at: copiedURL, attachments: [])
        let state = makeState(repository: repository, defaults: defaults)

        #expect(await state.openDocument(at: sourceURL))
        let oldSession = state.documentSessionToken
        let episodeID = source.chapters[0].episodes[0].id
        let chapterID = source.chapters[0].id
        let noteID = source.worldNotes[0].id
        let oldEditorGeneration = state.editorContentGeneration
        let oldEpisodeKey = SessionBoundEditorKey(value: episodeID, generation: oldEditorGeneration)
        let oldNoteKey = SessionBoundEditorKey(value: noteID, generation: oldEditorGeneration)

        #expect(await state.openDocument(at: copiedURL))
        let newSession = state.documentSessionToken
        let newEditorGeneration = state.editorContentGeneration
        #expect(oldEpisodeKey != SessionBoundEditorKey(value: episodeID, generation: newEditorGeneration))
        #expect(oldNoteKey != SessionBoundEditorKey(value: noteID, generation: newEditorGeneration))

        state.updateEpisodeContent("旧作品からの遅延通知", for: episodeID, in: chapterID, expectedSession: oldSession)
        state.updateWorldNoteContent("旧作品からの遅延通知", for: noteID, expectedSession: oldSession)

        #expect(state.document == copied)
    }

    @Test("作品切替の最終保存中は旧Workbenchからの変更を拒否する")
    func documentTransitionFreezesAllDocumentMutations() async {
        let repository = LifecycleRepository()
        let defaults = makeUserDefaults()
        let sourceURL = packageURL("TransitionFreezeSource")
        let targetURL = packageURL("TransitionFreezeTarget")
        let source = makeDocument(title: "切替元", chapterTitles: ["第1章"])
        let target = makeDocument(title: "切替先", chapterTitles: ["別章"])
        await repository.seed(source, at: sourceURL, attachments: [])
        await repository.seed(target, at: targetURL, attachments: [])
        let state = makeState(repository: repository, defaults: defaults)

        #expect(await state.openDocument(at: sourceURL))
        state.updateDocumentTitle("最終保存へ含める変更")
        let sourceSession = state.documentSessionToken
        let sourceChapterID = source.chapters[0].id
        let sourceEpisodeID = source.chapters[0].episodes[0].id
        await repository.pauseNextSave()

        let openTask = Task { @MainActor in
            await state.openDocument(at: targetURL)
        }
        await repository.waitUntilSaveIsPaused()

        #expect(state.isDocumentTransitionInProgress)
        #expect(!state.permitsDocumentInteraction)
        state.updateDocumentTitle("拒否されるタイトル")
        state.addChapter()
        state.updateEpisodeContent(
            "拒否される本文",
            for: sourceEpisodeID,
            in: sourceChapterID,
            expectedSession: sourceSession
        )

        await repository.resumeSave()
        #expect(await openTask.value)
        #expect(state.document == target)
        #expect(await repository.document(at: sourceURL)?.title == "最終保存へ含める変更")
        #expect(await repository.document(at: sourceURL)?.chapters.count == source.chapters.count)
        #expect(await repository.document(at: sourceURL)?.chapters[0].episodes[0].content == "第1章本文")
    }

    @Test("別名保存は切替直前のEditor確定本文を新保存先へ書く")
    func saveAsCommitsEditorBeforeAdvancingSession() async {
        let repository = LifecycleRepository()
        let defaults = makeUserDefaults()
        let sourceURL = packageURL("SaveAsEditorSource")
        let destinationURL = packageURL("SaveAsEditorDestination")
        let source = makeDocument(title: "別名保存IME", chapterTitles: ["第1章"])
        await repository.seed(source, at: sourceURL, attachments: [])
        let editorSession = EditorCommandSession()
        let state = makeState(
            repository: repository,
            defaults: defaults,
            editorCommandSession: editorSession
        )

        #expect(await state.openDocument(at: sourceURL))
        let expectedSession = state.documentSessionToken
        let editorGeneration = state.editorContentGeneration
        let chapterID = source.chapters[0].id
        let episodeID = source.chapters[0].episodes[0].id
        var didResume = false
        let handlerID = UUID()
        editorSession.registerDocumentLifecycleHandler(
            id: handlerID,
            prepare: {
                state.updateEpisodeContent(
                    "切替直前に確定した本文",
                    for: episodeID,
                    in: chapterID,
                    expectedSession: expectedSession
                )
                return true
            },
            resume: { didResume = true }
        )
        defer { editorSession.unregisterDocumentLifecycleHandler(id: handlerID) }

        #expect(await state.saveDocumentResult(as: destinationURL) == .saved)
        #expect(didResume)
        #expect(!editorSession.isDocumentTransitionPrepared)
        #expect(state.editorContentGeneration == editorGeneration)
        #expect(await repository.document(at: destinationURL)?.chapters[0].episodes[0].content == "切替直前に確定した本文")
    }

    @Test("終了要求後も表示中Editorの最終確定本文を保存する")
    func terminationAcceptsFinalEditorSynchronization() async {
        let repository = LifecycleRepository()
        let defaults = makeUserDefaults()
        let sourceURL = packageURL("TerminationEditorSource")
        let source = makeDocument(title: "終了IME", chapterTitles: ["第1章"])
        await repository.seed(source, at: sourceURL, attachments: [])
        let editorSession = EditorCommandSession()
        let state = makeState(
            repository: repository,
            defaults: defaults,
            editorCommandSession: editorSession
        )

        #expect(await state.openDocument(at: sourceURL))
        let expectedSession = state.documentSessionToken
        let chapterID = source.chapters[0].id
        let episodeID = source.chapters[0].episodes[0].id
        let handlerID = UUID()
        editorSession.registerDocumentLifecycleHandler(
            id: handlerID,
            prepare: {
                state.updateEpisodeContent(
                    "終了直前に確定した本文",
                    for: episodeID,
                    in: chapterID,
                    expectedSession: expectedSession
                )
                return true
            },
            resume: {}
        )
        defer { editorSession.unregisterDocumentLifecycleHandler(id: handlerID) }

        #expect(await state.saveBeforeTermination())
        #expect(await repository.document(at: sourceURL)?.chapters[0].episodes[0].content == "終了直前に確定した本文")
    }

    @Test("終了前保存の開始後は後続の作品操作を拒否し、最後の作品だけを保存する")
    func terminationClosesDocumentOperationGate() async throws {
        let repository = LifecycleRepository()
        let defaults = makeUserDefaults()
        let sourceURL = packageURL("TerminationSource")
        let finderURL = packageURL("TerminationFinder")
        let source = makeDocument(title: "終了対象", chapterTitles: ["第1章"])
        let finderDocument = makeDocument(title: "開いてはいけない作品", chapterTitles: ["別章"])
        await repository.seed(source, at: sourceURL, attachments: [])
        await repository.seed(finderDocument, at: finderURL, attachments: [])
        let editorCommandSession = EditorCommandSession()
        let state = makeState(
            repository: repository,
            defaults: defaults,
            editorCommandSession: editorCommandSession
        )

        #expect(await state.openDocument(at: sourceURL))
        let snapshotURL = try #require(await state.createSnapshot())
        state.updateSelectedEpisodeContent("終了直前の本文")
        await repository.pauseNextSnapshotSave()
        let restoreTask = Task { @MainActor in
            await state.restoreSnapshot(at: snapshotURL)
        }
        await repository.waitUntilSnapshotSaveIsPaused()

        var terminationDidStart = false
        let terminationTask = Task { @MainActor in
            terminationDidStart = true
            return await state.saveBeforeTermination()
        }
        while !terminationDidStart {
            await Task.yield()
        }

        #expect(await state.openExternalDocument(at: finderURL) == false)
        await repository.resumeSnapshotSave()
        #expect(await restoreTask.value)
        #expect(await terminationTask.value)

        #expect(state.documentURL == sourceURL.standardizedFileURL)
        #expect(state.document.title == source.title)
        #expect(await repository.document(at: finderURL) == finderDocument)
        #expect(editorCommandSession.isDocumentTransitionPrepared)
    }

    @Test("重複した終了要求は同じ最終保存へ合流し、一度だけ入力を確定する")
    func concurrentTerminationRequestsShareOneFlight() async {
        let repository = LifecycleRepository()
        let defaults = makeUserDefaults()
        let sourceURL = packageURL("ConcurrentTerminationSource")
        let source = makeDocument(title: "重複終了", chapterTitles: ["第1章"])
        await repository.seed(source, at: sourceURL, attachments: [])
        let editorSession = EditorCommandSession()
        let state = makeState(
            repository: repository,
            defaults: defaults,
            editorCommandSession: editorSession
        )

        #expect(await state.openDocument(at: sourceURL))
        state.updateDocumentTitle("終了時に保存する変更")
        var prepareCount = 0
        let handlerID = UUID()
        editorSession.registerDocumentLifecycleHandler(
            id: handlerID,
            prepare: {
                prepareCount += 1
                return true
            },
            resume: {}
        )
        defer { editorSession.unregisterDocumentLifecycleHandler(id: handlerID) }
        await repository.pauseNextSave()

        let first = Task { @MainActor in
            await state.saveBeforeTermination()
        }
        await repository.waitUntilSaveIsPaused()
        let second = Task { @MainActor in
            await state.saveBeforeTermination()
        }

        await repository.resumeSave()
        #expect(await first.value)
        #expect(await second.value)
        #expect(await state.saveBeforeTermination())
        #expect(prepareCount == 1)
        #expect(state.isDocumentTransitionInProgress)
        #expect(editorSession.isDocumentTransitionPrepared)
        #expect(await repository.document(at: sourceURL)?.title == "終了時に保存する変更")
    }

    private func makeState(
        repository: LifecycleRepository,
        defaults: UserDefaults,
        editorCommandSession: EditorCommandSession = EditorCommandSession()
    ) -> AppState {
        AppState(
            dependencies: AppDependencies(
                repository: repository,
                userDefaults: defaults,
                fileManager: .default,
                editorCommandSession: editorCommandSession
            ),
            initialStartupState: .ready
        )
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "FUMINIWALifecycleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func recentDocumentPath(in defaults: UserDefaults) -> String? {
        defaults.string(forKey: AppPreferenceKey.recentDocumentPath)
    }

    private func packageURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWALifecycleTests", isDirectory: true)
            .appendingPathComponent("\(name).novelpkg", isDirectory: true)
    }

    private func makeDocument(title: String, chapterTitles: [String]) -> NovelDocument {
        let chapters = chapterTitles.map {
            Chapter(title: $0, episodes: [Episode(content: "\($0)本文")])
        }
        return NovelDocument(
            title: title,
            chapters: chapters,
            characters: [NovelCore.Character(name: "人物")],
            plotCards: [PlotCard(title: "カード", chapterID: chapters.first?.id)],
            flags: [Flag(title: "伏線", plantedChapterID: chapters.first?.id)]
        )
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
    private var shouldPauseNextSave = false
    private var pausedSaveContinuation: CheckedContinuation<Void, Never>?
    private var loadPathToPause: String?
    private var pausedLoadContinuation: CheckedContinuation<Void, Never>?
    private var shouldPauseNextCopy = false
    private var pausedCopyContinuation: CheckedContinuation<Void, Never>?
    private var shouldPauseNextSnapshotSave = false
    private var pausedSnapshotSaveContinuation: CheckedContinuation<Void, Never>?
    private var restoredPackagePaths: [String] = []

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

    func pauseNextLoad(at url: URL) {
        loadPathToPause = key(url)
    }

    func pauseNextSave() {
        shouldPauseNextSave = true
    }

    func waitUntilSaveIsPaused() async {
        while pausedSaveContinuation == nil {
            await Task.yield()
        }
    }

    func resumeSave() {
        pausedSaveContinuation?.resume()
        pausedSaveContinuation = nil
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

    func pauseNextCopy() {
        shouldPauseNextCopy = true
    }

    func waitUntilCopyIsPaused() async {
        while pausedCopyContinuation == nil {
            await Task.yield()
        }
    }

    func resumeCopy() {
        pausedCopyContinuation?.resume()
        pausedCopyContinuation = nil
    }

    func pauseNextSnapshotSave() {
        shouldPauseNextSnapshotSave = true
    }

    func waitUntilSnapshotSaveIsPaused() async {
        while pausedSnapshotSaveContinuation == nil {
            await Task.yield()
        }
    }

    func resumeSnapshotSave() {
        pausedSnapshotSaveContinuation?.resume()
        pausedSnapshotSaveContinuation = nil
    }

    func restoreDestinations() -> [String] {
        restoredPackagePaths
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
        if loadPathToPause == key(url) {
            loadPathToPause = nil
            await withCheckedContinuation { continuation in
                pausedLoadContinuation = continuation
            }
        }
        guard !documentLoadFailurePaths.contains(key(url)), let document = documents[key(url)] else {
            throw LifecycleRepositoryError.loadFailed
        }
        return document
    }

    func save(_ doc: NovelDocument, to url: URL) async throws {
        if shouldPauseNextSave {
            shouldPauseNextSave = false
            await withCheckedContinuation { continuation in
                pausedSaveContinuation = continuation
            }
        }
        guard !shouldFailSave else { throw LifecycleRepositoryError.saveFailed }
        documents[key(url)] = doc
        storedAttachments[key(url)] = storedAttachments[key(url)] ?? []
    }

    func saveCopy(_ doc: NovelDocument, from sourceURL: URL, to destinationURL: URL) async throws {
        if shouldPauseNextCopy {
            shouldPauseNextCopy = false
            await withCheckedContinuation { continuation in
                pausedCopyContinuation = continuation
            }
        }
        guard !shouldFailCopy else { throw LifecycleRepositoryError.saveFailed }
        documents[key(destinationURL)] = doc
        storedAttachments[key(destinationURL)] = storedAttachments[key(sourceURL)] ?? []
        snapshotsByPackage[key(destinationURL)] = snapshotsByPackage[key(sourceURL)] ?? []
    }

    func saveSnapshot(_ doc: NovelDocument, to url: URL) async throws -> URL {
        if shouldPauseNextSnapshotSave {
            shouldPauseNextSnapshotSave = false
            await withCheckedContinuation { continuation in
                pausedSnapshotSaveContinuation = continuation
            }
        }
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
        restoredPackagePaths.append(key(packageURL))
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
