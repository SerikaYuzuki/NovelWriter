import AppKit
import EditorKit
import Foundation
import NovelCore
import NovelThumbnail
import NovelWorkspace

extension AppState {
    // MARK: - 選択中章

    /// Project Sidebar のセクションを選択する。UI2 では画面の主導線として使う。
    func selectProjectSection(_ section: ProjectSection) {
        guard workspaceSelection.section != section else { return }
        guard permitsDocumentInteraction else { return }
        workspaceSelection = WorkspaceSelection(section: section)
        if section == .worldbuilding {
            ensureWorldNoteSelection()
        }
    }

    /// 本文右クリックで取得したexact selectionから、原稿をコピーする。
    ///
    /// context menu表示後に作品や話が変わっていた場合は、同じ文字列が存在しても
    /// 現在選択へ読み替えない。IME変換中も未確定文字を欠いたコピー文字列を作らない。
    @discardableResult
    func copySelectionManuscript(
        selectedText: String,
        episodeID: EpisodeID,
        in chapterID: ChapterID,
        expectedSession: WorkspaceSessionToken
    ) -> Bool {
        let outcome = ManuscriptCopyCommand(host: self).copy(
            .selection(text: selectedText, chapterID: chapterID, episodeID: episodeID), expectedSession: expectedSession
        )
        presentManuscriptCopyNotice(outcome)
        return outcome == .success
    }

    /// 指定話のタイトルと本文だけを含む原稿をコピーする。
    @discardableResult
    func copyEpisodeManuscript(
        episodeID: EpisodeID,
        in chapterID: ChapterID,
        expectedSession: WorkspaceSessionToken
    ) -> Bool {
        let outcome = ManuscriptCopyCommand(host: self).copy(
            .episode(chapterID: chapterID, episodeID: episodeID), expectedSession: expectedSession
        )
        presentManuscriptCopyNotice(outcome)
        return outcome == .success
    }

    /// 指定章のタイトルと、配列順の全話タイトル／本文だけを含むコピー文字列をコピーする。
    @discardableResult
    func copyChapterManuscript(
        chapterID: ChapterID,
        expectedSession: WorkspaceSessionToken
    ) -> Bool {
        let outcome = ManuscriptCopyCommand(host: self).copy(.chapter(chapterID), expectedSession: expectedSession)
        presentManuscriptCopyNotice(outcome)
        return outcome == .success
    }

    func dismissManuscriptCopyNotice() {
        manuscriptCopyNoticeDismissTask?.cancel()
        manuscriptCopyNoticeDismissTask = nil
        manuscriptCopyNotice = nil
    }

    private func presentManuscriptCopyNotice(_ outcome: ManuscriptCopyOutcome) {
        manuscriptCopyNoticeDismissTask?.cancel()
        let notice = ManuscriptCopyNotice(outcome: outcome)
        manuscriptCopyNotice = notice
        manuscriptCopyNoticeDismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            guard let self, manuscriptCopyNotice?.id == notice.id else { return }
            manuscriptCopyNotice = nil
            manuscriptCopyNoticeDismissTask = nil
        }
    }

    /// 選択中の登場人物(存在しなければ `nil`)。
    var selectedCharacter: NovelCore.Character? {
        guard let selectedCharacterID else { return nil }
        return workspaceModel.document.characters.first { $0.id == selectedCharacterID }
    }

    /// 選択中のプロットカード(存在しなければ `nil`)。
    var selectedPlotCard: PlotCard? {
        guard let selectedPlotCardID else { return nil }
        return workspaceModel.document.plotCards.first { $0.id == selectedPlotCardID }
    }

    /// 選択中の伏線(存在しなければ `nil`)。
    var selectedFlag: Flag? {
        guard let selectedFlagID else { return nil }
        return workspaceModel.document.flags.first { $0.id == selectedFlagID }
    }

    /// 選択中の世界観ノート(存在しなければ `nil`)。
    var selectedWorldNote: WorldNote? {
        guard let selectedWorldNoteID else { return nil }
        return workspaceModel.document.worldNotes.first { $0.id == selectedWorldNoteID }
    }

    // MARK: - 世界観ノート

    /// 世界観ノートを追加し、追加したノートを選択する。
    func addWorldNote() {
        guard let id = projectFeatureCommands(.flushNow).addWorldNote(
            WorldNote(title: ""),
            expectedSession: workspaceModel.documentSessionToken
        ) else { return }
        selectedWorldNoteID = id
    }

    /// 世界観ノートを選択する。選択前の本文はdidChangeでモデルへ反映済みとする。
    func selectWorldNote(_ id: WorldNoteID?) {
        guard permitsDocumentInteraction else { return }
        guard id == nil || workspaceModel.document.worldNotes.contains(where: { $0.id == id }) else { return }
        guard selectedWorldNoteID != id else { return }
        selectedWorldNoteID = id
        flushSaveImmediately()
    }

    /// 世界観ノートのタイトルを更新する。空タイトルは編集中の値として許可する。
    func updateWorldNoteTitle(_ title: String, for id: WorldNoteID) {
        guard var note = workspaceModel.document.worldNotes.first(where: { $0.id == id }) else { return }
        note.title = title
        projectFeatureCommands(.debounced).updateWorldNote(note, expectedSession: workspaceModel.documentSessionToken)
    }

    /// 世界観ノートの本文を更新する。モデル反映は即時、保存だけをデバウンスする。
    func updateWorldNoteContent(
        _ content: String,
        for id: WorldNoteID,
        expectedSession: WorkspaceSessionToken? = nil
    ) {
        guard var note = workspaceModel.document.worldNotes.first(where: { $0.id == id }) else { return }
        note.content = content
        projectFeatureCommands(.debounced).updateWorldNote(
            note,
            expectedSession: expectedSession ?? workspaceModel.documentSessionToken
        )
    }

    /// 世界観ノートを削除し、隣接ノートへ選択を移す。
    @discardableResult
    func deleteWorldNote(id: WorldNoteID, expectedSession: WorkspaceSessionToken? = nil) -> Bool {
        guard let index = workspaceModel.document.worldNotes.firstIndex(where: { $0.id == id }),
              projectFeatureCommands(.flushNow).deleteWorldNote(
                  id: id,
                  expectedSession: expectedSession ?? workspaceModel.documentSessionToken
              ) else { return false }
        if selectedWorldNoteID == id {
            let fallbackIndex = min(index, max(workspaceModel.document.worldNotes.count - 1, 0))
            selectedWorldNoteID = workspaceModel.document.worldNotes.indices.contains(fallbackIndex)
                ? workspaceModel.document.worldNotes[fallbackIndex].id : nil
        }
        return true
    }

    /// 世界観ノートの並び順を更新する。
    func moveWorldNotes(fromOffsets: IndexSet, toOffset: Int) {
        projectFeatureCommands(.flushNow).moveWorldNotes(
            fromOffsets: fromOffsets,
            toOffset: toOffset,
            expectedSession: workspaceModel.documentSessionToken
        )
    }

    func ensureWorldNoteSelection() {
        if let selectedWorldNoteID,
           workspaceModel.document.worldNotes.contains(where: { $0.id == selectedWorldNoteID }) {
            return
        }
        selectedWorldNoteID = workspaceModel.document.worldNotes.first?.id
    }

    /// 章を選択する。最後に選択していた話、なければ先頭の話も選択する。
    /// 選択が変わるたびに即座に保存する(docs/DESIGN.md 6.4)。
    func selectChapter(_ id: ChapterID?) {
        guard permitsDocumentInteraction, id != workspaceModel.selectedChapterID else { return }
        if outlineCommands().selectChapter(id) {
            flushSaveImmediately()
        }
    }

    /// プロット画面の章Outline選択を更新する。章を選んだときは執筆側の章選択も揃える。
    func selectPlotOutline(_ selection: PlotOutlineSelection) {
        guard permitsDocumentInteraction else { return }
        guard selection != plotOutlineSelection else { return }
        if case let .chapter(chapterID) = selection, chapterID != workspaceModel.selectedChapterID {
            guard permitsDocumentInteraction else { return }
        }
        plotOutlineSelection = selection
        if case let .chapter(chapterID) = selection {
            setSelection(chapterID: chapterID, episodeID: preferredEpisodeID(in: chapterID))
            flushSaveImmediately()
        }
    }

    /// 話を選択する。`chapterID` を省略した場合は現在の章を対象にする。
    func selectEpisode(_ id: EpisodeID?, in chapterID: ChapterID? = nil) {
        guard let target = chapterID ?? workspaceModel.selectedChapterID else { return }
        if outlineCommands().selectEpisode(id, in: target) {
            flushSaveImmediately()
        }
    }

    // MARK: - 章操作(ロジックは NovelDocument 側のヘルパーに委譲)

    /// 章を末尾に追加し、追加した章を選択状態にする。
    func addChapter() {
        _ = outlineCommands(.flushNow).addChapter()
    }

    /// 指定章に話を追加し、追加した話を選択する。
    ///
    /// `title` を省略したときは、その章内の通し番号で「第N話」を付ける(UIFIX 2.1)。
    func addEpisode(to chapterID: ChapterID? = nil, title: String? = nil) {
        _ = outlineCommands(.flushNow).addEpisode(to: chapterID ?? workspaceModel.selectedChapterID, title: title)
    }

    /// 話のタイトルを更新する。
    func updateEpisodeTitle(_ title: String, for episodeID: EpisodeID, in chapterID: ChapterID) {
        outlineCommands(.debounced).renameEpisode(title, id: episodeID, in: chapterID)
    }

    /// 作品タイトルを更新する。空タイトルも編集中は許可し、保存はデバウンスする。
    func updateDocumentTitle(_ title: String) {
        guard permitsDocumentInteraction else { return }
        guard workspaceModel.document.title != title else { return }
        workspaceModel.document.title = title
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 作品あらすじを更新する。保存形式の詳細はNovelStorageに閉じ込める。
    func updateDocumentSynopsis(_ synopsis: String) {
        guard permitsDocumentInteraction else { return }
        guard workspaceModel.document.synopsis != synopsis else { return }
        workspaceModel.document.synopsis = synopsis
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 話タイトルの編集を確定し、空タイトルを既定値へ戻す。
    func commitEpisodeTitleEditing() {
        guard permitsDocumentInteraction else { return }
        for chapter in workspaceModel.document.chapters {
            for episode in chapter.episodes {
                let normalizedTitle = normalizedEpisodeTitle(episode.title)
                if episode.title != normalizedTitle {
                    workspaceModel.document.updateEpisodeTitle(normalizedTitle, for: episode.id, in: chapter.id)
                    saveCoordinator.markDirty()
                }
            }
        }
        flushSaveImmediately()
    }

    /// 章タイトルを更新する。タイトル編集中は頻繁に呼ばれるため保存はデバウンスする。
    func updateChapterTitle(_ title: String, for id: ChapterID) {
        outlineCommands(.debounced).renameChapter(title, id: id)
    }

    /// タイトル編集の確定時に、未保存分を即時保存へ寄せる。
    func commitChapterTitleEditing() {
        guard permitsDocumentInteraction else { return }
        for chapter in workspaceModel.document.chapters {
            let normalizedTitle = normalizedChapterTitle(chapter.title)
            if chapter.title != normalizedTitle {
                workspaceModel.document.updateTitle(normalizedTitle, for: chapter.id)
                saveCoordinator.markDirty()
            }
        }
        flushSaveImmediately()
    }

    /// 章を削除し、隣接章へ選択を移す。最後の1章は削除しない。
    @discardableResult
    func deleteChapter(id: ChapterID, expectedSession: WorkspaceSessionToken? = nil) -> Bool {
        outlineCommands(.flushNow).deleteChapter(id, expectedSession: expectedSession)
    }

    /// 章を並べ替える(`List.onMove` からそのまま呼べる形)。
    func moveChapters(fromOffsets: IndexSet, toOffset: Int) {
        outlineCommands(.flushNow).moveChapters(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    /// 章内の話を並べ替える。
    func moveEpisodes(in chapterID: ChapterID, fromOffsets: IndexSet, toOffset: Int) {
        outlineCommands(.flushNow).moveEpisodes(in: chapterID, fromOffsets: fromOffsets, toOffset: toOffset)
    }

    /// 話を同じ章内または別章へ移動する。
    @discardableResult
    func moveEpisode(
        id episodeID: EpisodeID,
        from sourceChapterID: ChapterID,
        to destinationChapterID: ChapterID,
        before targetEpisodeID: EpisodeID? = nil
    ) -> Bool {
        outlineCommands(.flushNow).moveEpisode(episodeID, from: sourceChapterID, to: destinationChapterID, before: targetEpisodeID)
    }

    /// 選択中章の本文を更新する。編集のたびに呼ばれる想定で、モデル更新は即座に行い、
    /// ディスクへの保存は2秒デバウンスする(テキスト所有権ルール D-005。
    /// `EditorView` から編集中に本文を書き戻すことはしない)。
    func updateSelectedEpisodeContent(_ content: String) {
        guard let selectedChapterID = workspaceModel.selectedChapterID, let selectedEpisodeID = workspaceModel.selectedEpisodeID else { return }
        updateEpisodeContent(content, for: selectedEpisodeID, in: selectedChapterID)
    }

    /// 表示時に固定した話・章・作品セッションへ本文を反映する。
    ///
    /// 作品遷移前のIME確定通知が、遷移先の「現在選択」へ流れ込まないよう、
    /// EditorViewのcallbackはこのAPIへ固定IDとsessionを渡す。
    func updateEpisodeContent(
        _ content: String,
        for episodeID: EpisodeID,
        in chapterID: ChapterID,
        expectedSession: WorkspaceSessionToken? = nil,
        expectedEditorContentGeneration: UInt64? = nil
    ) {
        guard permitsEditorSynchronization(expectedSession: expectedSession) else { return }
        if let expectedEditorContentGeneration {
            guard workspaceModel.editorContentGeneration == expectedEditorContentGeneration else { return }
        }
        guard let chapter = workspaceModel.document.chapters.first(where: { $0.id == chapterID }),
              let episode = chapter.episodes.first(where: { $0.id == episodeID }),
              episode.content != content else { return }
        if let workID = currentSnapshotSyncV2WorkID {
            writingProgress.manualChange(document: workspaceModel.document, workID: workID.rawValue, episodeID: episodeID, content: content, previousContent: episode.content)
        }
        if let application = snapshotSyncV2Application, let workID = currentSnapshotSyncV2WorkID {
            Task { await application.recordBodyEdit(workID: workID) }
        }
        workspaceModel.document.updateEpisodeContent(content, for: episodeID, in: chapterID)
        editorProgressAlreadyTracked = true
        defer { editorProgressAlreadyTracked = false }
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 選択中章のメモを更新する。メモは短文想定の補助情報なので SwiftUI 側の
    /// `TextEditor` から通常の Binding 更新で呼ばれる。
    func updateSelectedEpisodeMemo(_ memo: String) {
        guard permitsDocumentInteraction else { return }
        guard let selectedChapterID = workspaceModel.selectedChapterID, let selectedEpisodeID = workspaceModel.selectedEpisodeID else { return }
        guard selectedEpisode?.memo != memo else { return }
        workspaceModel.document.updateEpisodeMemo(memo, for: selectedEpisodeID, in: selectedChapterID)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }
}
