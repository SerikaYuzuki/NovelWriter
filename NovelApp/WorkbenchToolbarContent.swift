import AppKit
import NovelCore
import SwiftUI

/// Workbench 上部の一段 native toolbar(docs/TOOLBAR.md Toolbar-2 / D-024)。
///
/// `NovelWorkbenchView` だけが `.toolbar(id:)` を所有する。編集操作は個別の
/// `ToolbarItem(id:)` とし、Sidebar 開閉・Outline identity・右端検索は
/// システムの固定アンカーに委ねる。
struct WorkbenchToolbarContent: CustomizableToolbarContent {
    @Environment(AppState.self) private var appState
    @Environment(SnapshotMenuPresenter.self) private var snapshotMenuPresenter

    @Binding var isMemoPresented: Bool
    let showsWritingActions: Bool
    let onOpenCharacter: (CharacterID) -> Void
    let onOpenPlotCard: (PlotCardID) -> Void

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: WorkbenchToolbarItemID.chapterAdd) {
            Button {
                appState.addChapter()
            } label: {
                Label("章を追加", systemImage: "plus")
            }
            .help("章を追加")
            .disabled(!showsWritingActions)
        }
        .defaultCustomization(.visible)

        ToolbarItem(id: WorkbenchToolbarItemID.chapterMemo) {
            Button {
                isMemoPresented.toggle()
            } label: {
                Label("章メモ", systemImage: "note.text")
            }
            .help("章メモ")
            .disabled(appState.selectedEpisode == nil || !showsWritingActions)
        }
        .defaultCustomization(.visible)

        ToolbarItem(id: WorkbenchToolbarItemID.snapshotSave) {
            Button {
                Task {
                    _ = await appState.createSnapshot()
                    await snapshotMenuPresenter.refresh()
                }
            } label: {
                Label("スナップショットを保存", systemImage: "clock.arrow.circlepath")
            }
            .help("スナップショットを保存")
            .disabled(!showsWritingActions)
        }
        .defaultCustomization(.visible)

        ToolbarItem(id: WorkbenchToolbarItemID.chapterContext) {
            Menu {
                ChapterContextMenuContent(
                    appState: appState,
                    onOpenCharacter: onOpenCharacter,
                    onOpenPlotCard: onOpenPlotCard
                )
            } label: {
                Label("この章", systemImage: "doc.text.magnifyingglass")
            }
            .help("この章")
            .disabled(appState.selectedChapter == nil || !showsWritingActions)
        }
        .defaultCustomization(.visible)
    }
}

enum WorkbenchToolbarItemID {
    static let chapterAdd = "workbench.chapter.add"
    static let chapterMemo = "workbench.chapter.memo"
    static let snapshotSave = "workbench.snapshot.save"
    static let chapterContext = "workbench.chapter.context"
}

struct ChapterMemoPopover: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("章メモ")
                .font(.headline)
            TextEditor(text: memoBinding)
        }
        .padding(12)
    }

    private var memoBinding: Binding<String> {
        Binding(
            get: { appState.selectedEpisode?.memo ?? "" },
            set: { appState.updateSelectedEpisodeMemo($0) }
        )
    }
}

struct ChapterContextMenuContent: View {
    @Bindable var appState: AppState

    /// 指定時はその章を対象にする。未指定時は現在の選択章。
    var chapterID: ChapterID?
    let onOpenCharacter: (CharacterID) -> Void
    let onOpenPlotCard: (PlotCardID) -> Void

    var body: some View {
        Section("プロットカード") {
            if chapterPlotCards.isEmpty {
                Text("プロットカードがありません")
            } else {
                ForEach(chapterPlotCards) { card in
                    Button(NovelDocument.normalizedPlotCardTitle(card.title)) {
                        onOpenPlotCard(card.id)
                    }
                }
            }
        }

        Section("登場人物") {
            if appearingCharacters.isEmpty {
                Text("登場人物がありません")
            } else {
                ForEach(appearingCharacters) { character in
                    Button(NovelDocument.normalizedCharacterName(character.name)) {
                        onOpenCharacter(character.id)
                    }
                }
            }
        }
    }

    private var targetChapterID: ChapterID? {
        chapterID ?? appState.selection
    }

    private var targetChapter: Chapter? {
        guard let targetChapterID else { return nil }
        return appState.document.chapters.first { $0.id == targetChapterID }
    }

    private var chapterPlotCards: [PlotCard] {
        guard let targetChapterID else { return [] }
        return appState.document.plotCards.filter { $0.chapterID == targetChapterID }
    }

    private var appearingCharacters: [NovelCore.Character] {
        guard let chapter = targetChapter else { return [] }
        return appState.document.characters.filter { character in
            CharacterAppearanceDetector.appearances(
                for: character,
                in: NovelDocument(
                    id: appState.document.id,
                    title: appState.document.title,
                    chapters: [chapter],
                    characters: [],
                    plotCards: [],
                    flags: []
                )
            ).isEmpty == false
        }
    }
}

/// File メニューからスナップショット一覧・復元へ到達するための薄い状態。
@MainActor
@Observable
final class SnapshotMenuPresenter {
    var snapshots: [DocumentSnapshotInfo] = []
    var snapshotPendingRestore: DocumentSnapshotInfo?
    var restoreErrorMessage: String?

    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    func refresh() async {
        snapshots = await appState.listSnapshots()
    }

    func restore(_ snapshot: DocumentSnapshotInfo) async {
        let success = await appState.restoreSnapshot(at: snapshot.url)
        await refresh()
        if !success {
            restoreErrorMessage = "スナップショットを復元できませんでした。保存に失敗したか、ファイルにアクセスできない可能性があります。"
        }
    }
}
