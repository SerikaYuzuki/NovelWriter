import AppKit
import EditorKit
import Foundation
import NovelCore
import NovelThumbnail

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
        expectedSession: DocumentSessionToken
    ) -> Bool {
        let episodeStillExists = document.chapters.first(where: { $0.id == chapterID })?
            .episodes.contains(where: { $0.id == episodeID }) == true
        let isCurrentSelection = isCurrentManuscriptCopyContext(expectedSession) &&
            workspaceSelection.section == .structure &&
            selectedChapterID == chapterID &&
            selectedEpisodeID == episodeID &&
            episodeStillExists
        guard isCurrentSelection else {
            return failManuscriptCopy(.staleContext)
        }

        switch activeCommittedTextCapture() {
        case .captured:
            return copyManuscript(
                source: .selection(text: selectedText)
            )
        case .compositionInProgress:
            return failManuscriptCopy(.compositionInProgress)
        case .notActive:
            return failManuscriptCopy(.staleContext)
        }
    }

    /// 指定話のタイトルと本文だけを含む原稿をコピーする。
    @discardableResult
    func copyEpisodeManuscript(
        episodeID: EpisodeID,
        in chapterID: ChapterID,
        expectedSession: DocumentSessionToken
    ) -> Bool {
        guard isCurrentManuscriptCopyContext(expectedSession) else {
            return failManuscriptCopy(.staleContext)
        }
        guard let chapter = document.chapters.first(where: { $0.id == chapterID }) else {
            return failManuscriptCopy(.staleContext)
        }
        guard let episode = chapter.episodes.first(where: { $0.id == episodeID }) else {
            return failManuscriptCopy(.staleContext)
        }

        let content: String
        if workspaceSelection.section == .structure,
           selectedChapterID == chapterID,
           selectedEpisodeID == episodeID {
            switch activeCommittedTextCapture() {
            case let .captured(committedText):
                content = committedText
            case .compositionInProgress:
                return failManuscriptCopy(.compositionInProgress)
            case .notActive:
                content = episode.content
            }
        } else {
            content = episode.content
        }

        return copyManuscript(
            source: .episode(title: episode.title, content: content)
        )
    }

    /// 指定章のタイトルと、配列順の全話タイトル／本文だけを含むコピー文字列をコピーする。
    @discardableResult
    func copyChapterManuscript(
        chapterID: ChapterID,
        expectedSession: DocumentSessionToken
    ) -> Bool {
        guard isCurrentManuscriptCopyContext(expectedSession) else {
            return failManuscriptCopy(.staleContext)
        }
        guard let chapter = document.chapters.first(where: { $0.id == chapterID }) else {
            return failManuscriptCopy(.staleContext)
        }

        var activeEpisodeContent: (id: EpisodeID, text: String)?
        let selectedEpisodeBelongsToChapter = selectedEpisodeID.map { selectedEpisodeID in
            chapter.episodes.contains(where: { $0.id == selectedEpisodeID })
        } ?? false
        let activeEpisodeID = workspaceSelection.section == .structure &&
            selectedChapterID == chapterID && selectedEpisodeBelongsToChapter
            ? selectedEpisodeID
            : nil
        if let activeEpisodeID {
            switch activeCommittedTextCapture() {
            case let .captured(committedText):
                activeEpisodeContent = (activeEpisodeID, committedText)
            case .compositionInProgress:
                return failManuscriptCopy(.compositionInProgress)
            case .notActive:
                break
            }
        }

        let episodes = chapter.episodes.map { episode in
            ManuscriptCopyEpisode(
                title: episode.title,
                content: activeEpisodeContent?.id == episode.id
                    ? activeEpisodeContent?.text ?? episode.content
                    : episode.content
            )
        }
        return copyManuscript(
            source: .chapter(title: chapter.title, episodes: episodes)
        )
    }

    func dismissManuscriptCopyNotice() {
        manuscriptCopyNoticeDismissTask?.cancel()
        manuscriptCopyNoticeDismissTask = nil
        manuscriptCopyNotice = nil
    }

    private func isCurrentManuscriptCopyContext(_ expectedSession: DocumentSessionToken) -> Bool {
        permitsDocumentInteraction && documentSessionToken == expectedSession
    }

    @discardableResult
    private func copyManuscript(
        source: ManuscriptCopySource
    ) -> Bool {
        do {
            let prompt = try ManuscriptCopyBuilder.make(source: source)
            guard clipboardWriter.writePlainText(prompt.text) else {
                return failManuscriptCopy(.clipboardWriteFailed)
            }
            presentManuscriptCopyNotice(.success)
            return true
        } catch let error as ManuscriptCopyError {
            return failManuscriptCopy(copyFailure(for: error))
        } catch {
            return failManuscriptCopy(.copyPreparationFailed)
        }
    }

    private func copyFailure(for error: ManuscriptCopyError) -> ManuscriptCopyFailure {
        switch error {
        case .emptyContent:
            .emptyContent
        case .sourceCharacterLimitExceeded, .sourceUTF8ByteLimitExceeded, .outputUTF8ByteLimitExceeded:
            .contentTooLarge
        }
    }

    @discardableResult
    private func failManuscriptCopy(_ failure: ManuscriptCopyFailure) -> Bool {
        presentManuscriptCopyNotice(.failure(failure))
        return false
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
        return document.characters.first { $0.id == selectedCharacterID }
    }

    /// 選択中のプロットカード(存在しなければ `nil`)。
    var selectedPlotCard: PlotCard? {
        guard let selectedPlotCardID else { return nil }
        return document.plotCards.first { $0.id == selectedPlotCardID }
    }

    /// 選択中の伏線(存在しなければ `nil`)。
    var selectedFlag: Flag? {
        guard let selectedFlagID else { return nil }
        return document.flags.first { $0.id == selectedFlagID }
    }

    /// 選択中の世界観ノート(存在しなければ `nil`)。
    var selectedWorldNote: WorldNote? {
        guard let selectedWorldNoteID else { return nil }
        return document.worldNotes.first { $0.id == selectedWorldNoteID }
    }

    // MARK: - 世界観ノート

    /// 世界観ノートを追加し、追加したノートを選択する。
    func addWorldNote() {
        guard permitsDocumentInteraction else { return }
        let note = WorldNote(title: "")
        document.worldNotes.append(note)
        selectedWorldNoteID = note.id
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// 世界観ノートを選択する。選択前の本文はdidChangeでモデルへ反映済みとする。
    func selectWorldNote(_ id: WorldNoteID?) {
        guard permitsDocumentInteraction else { return }
        guard id == nil || document.worldNotes.contains(where: { $0.id == id }) else { return }
        guard selectedWorldNoteID != id else { return }
        selectedWorldNoteID = id
        flushSaveImmediately()
    }

    /// 世界観ノートのタイトルを更新する。空タイトルは編集中の値として許可する。
    func updateWorldNoteTitle(_ title: String, for id: WorldNoteID) {
        guard permitsDocumentInteraction else { return }
        guard let index = document.worldNotes.firstIndex(where: { $0.id == id }),
              document.worldNotes[index].title != title else { return }
        document.worldNotes[index].title = title
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 世界観ノートの本文を更新する。モデル反映は即時、保存だけをデバウンスする。
    func updateWorldNoteContent(
        _ content: String,
        for id: WorldNoteID,
        expectedSession: DocumentSessionToken? = nil
    ) {
        guard permitsEditorSynchronization(expectedSession: expectedSession) else { return }
        guard let index = document.worldNotes.firstIndex(where: { $0.id == id }),
              document.worldNotes[index].content != content else { return }
        document.worldNotes[index].content = content
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 世界観ノートを削除し、隣接ノートへ選択を移す。
    @discardableResult
    func deleteWorldNote(id: WorldNoteID, expectedSession: DocumentSessionToken? = nil) -> Bool {
        guard permitsMutation(expectedSession: expectedSession) else { return false }
        guard let index = document.worldNotes.firstIndex(where: { $0.id == id }) else { return false }
        var replacement = document
        replacement.worldNotes.remove(at: index)
        applyOwnerRemoval(replacement)
        if selectedWorldNoteID == id {
            let fallbackIndex = min(index, max(document.worldNotes.count - 1, 0))
            selectedWorldNoteID = document.worldNotes.indices.contains(fallbackIndex)
                ? document.worldNotes[fallbackIndex].id
                : nil
        }
        saveCoordinator.markDirty()
        flushSaveImmediately()
        return true
    }

    /// 世界観ノートの並び順を更新する。
    func moveWorldNotes(fromOffsets: IndexSet, toOffset: Int) {
        guard permitsDocumentInteraction else { return }
        document.worldNotes.move(fromOffsets: fromOffsets, toOffset: toOffset)
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    func ensureWorldNoteSelection() {
        if let selectedWorldNoteID,
           document.worldNotes.contains(where: { $0.id == selectedWorldNoteID }) {
            return
        }
        selectedWorldNoteID = document.worldNotes.first?.id
    }

    /// 章を選択する。最後に選択していた話、なければ先頭の話も選択する。
    /// 選択が変わるたびに即座に保存する(docs/DESIGN.md 6.4)。
    func selectChapter(_ id: ChapterID?) {
        guard permitsDocumentInteraction else { return }
        guard id != selectedChapterID else { return }
        guard permitsDocumentInteraction else { return }
        setSelection(chapterID: id, episodeID: id.flatMap(preferredEpisodeID(in:)))
        flushSaveImmediately()
    }

    /// プロット画面の章Outline選択を更新する。章を選んだときは執筆側の章選択も揃える。
    func selectPlotOutline(_ selection: PlotOutlineSelection) {
        guard permitsDocumentInteraction else { return }
        guard selection != plotOutlineSelection else { return }
        if case let .chapter(chapterID) = selection, chapterID != selectedChapterID {
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
        guard permitsDocumentInteraction else { return }
        let targetChapterID = chapterID ?? selectedChapterID
        guard let targetChapterID else { return }
        guard targetChapterID == selectedChapterID && id == selectedEpisodeID ||
            permitsDocumentInteraction else { return }
        guard let id else {
            guard document.chapters.first(where: { $0.id == targetChapterID })?.episodes.isEmpty == true else { return }
            setSelection(chapterID: targetChapterID, episodeID: nil)
            flushSaveImmediately()
            return
        }
        guard document.chapters.contains(where: { chapter in
            chapter.id == targetChapterID && chapter.episodes.contains(where: { $0.id == id })
        }) else { return }
        setSelection(chapterID: targetChapterID, episodeID: id)
        flushSaveImmediately()
    }

    // MARK: - 章操作(ロジックは NovelDocument 側のヘルパーに委譲)

    /// 章を末尾に追加し、追加した章を選択状態にする。
    func addChapter() {
        guard permitsDocumentInteraction else { return }
        guard permitsDocumentInteraction else { return }
        let title = "第\(document.chapters.count + 1)章"
        let newID = document.addChapter(title: title)
        setSelection(chapterID: newID, episodeID: nil)
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// 指定章に話を追加し、追加した話を選択する。
    ///
    /// `title` を省略したときは、その章内の通し番号で「第N話」を付ける(UIFIX 2.1)。
    func addEpisode(to chapterID: ChapterID? = nil, title: String? = nil) {
        guard permitsDocumentInteraction else { return }
        guard permitsDocumentInteraction else { return }
        let targetChapterID = chapterID ?? selectedChapterID
        guard let targetChapterID,
              let chapter = document.chapters.first(where: { $0.id == targetChapterID }) else { return }
        let resolvedTitle = title ?? "第\(chapter.episodes.count + 1)話"
        guard let episodeID = document.addEpisode(to: targetChapterID, title: resolvedTitle) else { return }
        setSelection(chapterID: targetChapterID, episodeID: episodeID)
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// 選択中話のタイトルを更新する。
    func updateSelectedEpisodeTitle(_ title: String) {
        guard permitsDocumentInteraction else { return }
        guard let selectedEpisodeID, let selectedChapterID else { return }
        guard selectedEpisode?.title != title else { return }
        document.updateEpisodeTitle(title, for: selectedEpisodeID, in: selectedChapterID)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 話のタイトルを更新する。
    func updateEpisodeTitle(_ title: String, for episodeID: EpisodeID, in chapterID: ChapterID) {
        guard permitsDocumentInteraction else { return }
        guard let episode = document.chapters.first(where: { $0.id == chapterID })?.episodes.first(where: { $0.id == episodeID }),
              episode.title != title else { return }
        document.updateEpisodeTitle(title, for: episodeID, in: chapterID)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 作品タイトルを更新する。空タイトルも編集中は許可し、保存はデバウンスする。
    func updateDocumentTitle(_ title: String) {
        guard permitsDocumentInteraction else { return }
        guard document.title != title else { return }
        document.title = title
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 作品あらすじを更新する。保存形式の詳細はNovelStorageに閉じ込める。
    func updateDocumentSynopsis(_ synopsis: String) {
        guard permitsDocumentInteraction else { return }
        guard document.synopsis != synopsis else { return }
        document.synopsis = synopsis
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 話タイトルの編集を確定し、空タイトルを既定値へ戻す。
    func commitEpisodeTitleEditing() {
        guard permitsDocumentInteraction else { return }
        for chapter in document.chapters {
            for episode in chapter.episodes {
                let normalizedTitle = normalizedEpisodeTitle(episode.title)
                if episode.title != normalizedTitle {
                    document.updateEpisodeTitle(normalizedTitle, for: episode.id, in: chapter.id)
                    saveCoordinator.markDirty()
                }
            }
        }
        flushSaveImmediately()
    }

    /// 章タイトルを更新する。タイトル編集中は頻繁に呼ばれるため保存はデバウンスする。
    func updateChapterTitle(_ title: String, for id: ChapterID) {
        guard permitsDocumentInteraction else { return }
        guard document.chapters.first(where: { $0.id == id })?.title != title else { return }
        document.updateTitle(title, for: id)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// タイトル編集の確定時に、未保存分を即時保存へ寄せる。
    func commitChapterTitleEditing() {
        guard permitsDocumentInteraction else { return }
        for chapter in document.chapters {
            let normalizedTitle = normalizedChapterTitle(chapter.title)
            if chapter.title != normalizedTitle {
                document.updateTitle(normalizedTitle, for: chapter.id)
                saveCoordinator.markDirty()
            }
        }
        flushSaveImmediately()
    }

    /// 章を削除し、隣接章へ選択を移す。最後の1章は削除しない。
    @discardableResult
    func deleteChapter(id: ChapterID, expectedSession: DocumentSessionToken? = nil) -> Bool {
        guard permitsMutation(expectedSession: expectedSession) else { return false }
        if selectedChapterID == id {
            guard permitsDocumentInteraction else { return false }
        }
        guard document.chapters.count > 1 else { return false }
        guard let originalIndex = document.chapters.firstIndex(where: { $0.id == id }) else { return false }
        guard document.removeChapter(id: id) != nil else { return false }

        if selectedChapterID == id {
            let fallbackIndex = min(originalIndex, document.chapters.count - 1)
            let fallbackChapterID = document.chapters.indices.contains(fallbackIndex) ? document.chapters[fallbackIndex].id : nil
            setSelection(chapterID: fallbackChapterID, episodeID: fallbackChapterID.flatMap(preferredEpisodeID(in:)))
        }
        if case let .chapter(focusedID) = plotOutlineSelection, focusedID == id {
            if let selectedChapterID {
                plotOutlineSelection = .chapter(selectedChapterID)
            } else {
                plotOutlineSelection = .unassigned
            }
        }

        saveCoordinator.markDirty()
        flushSaveImmediately()
        return true
    }

    /// 章を並べ替える(`List.onMove` からそのまま呼べる形)。
    func moveChapters(fromOffsets: IndexSet, toOffset: Int) {
        guard permitsDocumentInteraction else { return }
        document.moveChapters(fromOffsets: fromOffsets, toOffset: toOffset)
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// 話を削除し、同じ章の隣接話へ選択を移す。
    @discardableResult
    func deleteEpisode(
        id episodeID: EpisodeID,
        from chapterID: ChapterID? = nil,
        expectedSession: DocumentSessionToken? = nil
    ) -> Bool {
        guard permitsMutation(expectedSession: expectedSession) else { return false }
        if selectedEpisodeID == episodeID {
            guard permitsDocumentInteraction else { return false }
        }
        let sourceChapterID = chapterID ?? selectedChapterID
        guard let sourceChapterID,
              let originalIndex = document.episode(episodeID)?.chapterID == sourceChapterID
              ? document.chapters.first(where: { $0.id == sourceChapterID })?.episodes.firstIndex(where: { $0.id == episodeID })
              : nil,
              document.removeEpisode(id: episodeID, from: sourceChapterID) != nil else { return false }

        if selectedEpisodeID == episodeID {
            let remaining = document.chapters.first(where: { $0.id == sourceChapterID })?.episodes ?? []
            let fallbackIndex = min(originalIndex, max(remaining.count - 1, 0))
            let fallbackEpisodeID = remaining.indices.contains(fallbackIndex) ? remaining[fallbackIndex].id : nil
            setSelection(chapterID: sourceChapterID, episodeID: fallbackEpisodeID)
        }
        saveCoordinator.markDirty()
        flushSaveImmediately()
        return true
    }

    /// 章内の話を並べ替える。
    func moveEpisodes(in chapterID: ChapterID, fromOffsets: IndexSet, toOffset: Int) {
        guard permitsDocumentInteraction else { return }
        document.moveEpisodes(in: chapterID, fromOffsets: fromOffsets, toOffset: toOffset)
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// 話を同じ章内または別章へ移動する。
    @discardableResult
    func moveEpisode(
        id episodeID: EpisodeID,
        from sourceChapterID: ChapterID,
        to destinationChapterID: ChapterID,
        before targetEpisodeID: EpisodeID? = nil
    ) -> Bool {
        guard permitsDocumentInteraction else { return false }
        if selectedEpisodeID == episodeID, selectedChapterID != destinationChapterID {
            guard permitsDocumentInteraction else { return false }
        }
        guard document.moveEpisode(
            id: episodeID,
            from: sourceChapterID,
            to: destinationChapterID,
            before: targetEpisodeID
        ) else { return false }
        if selectedEpisodeID == episodeID {
            setSelection(chapterID: destinationChapterID, episodeID: episodeID)
        }
        saveCoordinator.markDirty()
        flushSaveImmediately()
        return true
    }

    /// 選択中章の本文を更新する。編集のたびに呼ばれる想定で、モデル更新は即座に行い、
    /// ディスクへの保存は2秒デバウンスする(テキスト所有権ルール D-005。
    /// `EditorView` から編集中に本文を書き戻すことはしない)。
    func updateSelectedEpisodeContent(_ content: String) {
        guard let selectedChapterID, let selectedEpisodeID else { return }
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
        expectedSession: DocumentSessionToken? = nil,
        expectedEditorContentGeneration: UInt64? = nil
    ) {
        guard permitsEditorSynchronization(expectedSession: expectedSession) else { return }
        if let expectedEditorContentGeneration {
            guard editorContentGeneration == expectedEditorContentGeneration else { return }
        }
        guard let chapter = document.chapters.first(where: { $0.id == chapterID }),
              let episode = chapter.episodes.first(where: { $0.id == episodeID }),
              episode.content != content else { return }
        if let workID = currentSnapshotSyncV2WorkID {
            writingProgress.manualChange(document: document, workID: workID.rawValue, episodeID: episodeID, content: content, previousContent: episode.content)
        }
        if let application = snapshotSyncV2Application, let workID = currentSnapshotSyncV2WorkID {
            Task { await application.recordBodyEdit(workID: workID) }
        }
        document.updateEpisodeContent(content, for: episodeID, in: chapterID)
        editorProgressAlreadyTracked = true
        defer { editorProgressAlreadyTracked = false }
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    func advanceEditorContentGenerationForSurfaceTransition() {
        editorContentGeneration &+= 1
    }

    /// 選択中章のメモを更新する。メモは短文想定の補助情報なので SwiftUI 側の
    /// `TextEditor` から通常の Binding 更新で呼ばれる。
    func updateSelectedEpisodeMemo(_ memo: String) {
        guard permitsDocumentInteraction else { return }
        guard let selectedChapterID, let selectedEpisodeID else { return }
        guard selectedEpisode?.memo != memo else { return }
        document.updateEpisodeMemo(memo, for: selectedEpisodeID, in: selectedChapterID)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }
}
