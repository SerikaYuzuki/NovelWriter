import AppKit
import NovelCore
import Observation
import SwiftUI

/// Workbench 上部の一段 native toolbar(docs/TOOLBAR.md Toolbar-2 / D-024)。
///
/// `NovelWorkbenchView` だけが `.toolbar(id:)` を所有する。編集操作は個別の
/// `ToolbarItem(id:)` とし、Sidebar 開閉・Outline identity・右端検索は
/// システムの固定アンカーに委ねる。
struct WorkbenchToolbarContent: CustomizableToolbarContent {
    @Environment(AppState.self) private var appState
    @Environment(SnapshotMenuPresenter.self) private var snapshotMenuPresenter

    let overlayState: WorkbenchOverlayState
    let showsWritingActions: Bool

    var body: some CustomizableToolbarContent {
        if showsWritingActions {
            ToolbarItem(id: WorkbenchToolbarItemID.episodeAdd, placement: .navigation) {
                Button {
                    appState.addEpisode()
                } label: {
                    Label("話を追加", systemImage: "square.and.pencil")
                }
                .help("選択中の章に話を追加")
                .disabled(appState.selectedChapter == nil)
            }
            .customizationBehavior(.disabled)
            .defaultCustomization(.visible)

            ToolbarItem(id: WorkbenchToolbarItemID.chapterMemo) {
                Button {
                    overlayState.toggle(.memo)
                } label: {
                    Label("話メモ", systemImage: "note.text")
                }
                .help("話メモ")
                .disabled(appState.selectedEpisode == nil)
                .popover(isPresented: isPresented(.memo), arrowEdge: .bottom) {
                    ChapterMemoPopover()
                        .frame(width: 320, height: 260)
                }
            }
            .customizationBehavior(.reorderable)
            .defaultCustomization(.visible)

            ToolbarItem(id: WorkbenchToolbarItemID.snapshotSave) {
                Button {
                    overlayState.toggle(.snapshots)
                } label: {
                    Label("スナップショット", systemImage: "clock.arrow.circlepath")
                }
                .help("スナップショットの保存・一覧")
                .popover(isPresented: isPresented(.snapshots), arrowEdge: .bottom) {
                    SnapshotPopover(overlayState: overlayState)
                        .frame(width: 360, height: 320)
                }
            }
            .customizationBehavior(.reorderable)
            .defaultCustomization(.visible)
        }

        if showsPlotActions {
            ToolbarItem(id: WorkbenchToolbarItemID.plotCardAdd) {
                Button {
                    appState.addPlotCard(chapterID: selectedPlotChapterID)
                } label: {
                    Label("プロットカードを追加", systemImage: "rectangle.stack.badge.plus")
                }
                .help("プロットカードを追加")
            }
            .customizationBehavior(.reorderable)
            .defaultCustomization(.visible)
        }

        if showsWritingActions || showsPlotActions {
            ToolbarItem(id: WorkbenchToolbarItemID.chapterAdd, placement: .navigation) {
                Button {
                    appState.addChapter()
                } label: {
                    Label("章を追加", systemImage: "plus")
                }
                .help("章を追加")
            }
            .customizationBehavior(.disabled)
            .defaultCustomization(.visible)
        }

        if showsCharacterActions {
            ToolbarItem(id: WorkbenchToolbarItemID.characterAdd, placement: .navigation) {
                Button {
                    appState.addCharacter()
                } label: {
                    Label("登場人物を追加", systemImage: "person.badge.plus")
                }
                .help("登場人物を追加")
            }
            .customizationBehavior(.disabled)
            .defaultCustomization(.visible)
        }

        if showsWorldbuildingActions {
            ToolbarItem(id: WorkbenchToolbarItemID.worldNoteAdd, placement: .navigation) {
                Button {
                    appState.addWorldNote()
                } label: {
                    Label("ノートを追加", systemImage: "note.text.badge.plus")
                }
                .help("ノートを追加")
            }
            .customizationBehavior(.disabled)
            .defaultCustomization(.visible)
        }

        if showsReferenceActions {
            ToolbarItem(id: WorkbenchToolbarItemID.attachmentAdd, placement: .navigation) {
                Button {
                    NotificationCenter.default.post(name: .presentAttachmentImporter, object: nil)
                } label: {
                    Label("資料を取り込む", systemImage: "paperclip")
                }
                .help("資料を取り込む")
                .disabled(!appState.supportsAttachments)
            }
            .customizationBehavior(.disabled)
            .defaultCustomization(.visible)
        }
    }

    private var showsCharacterActions: Bool {
        appState.workspaceSelection.section == .characters
    }

    private var showsPlotActions: Bool {
        appState.workspaceSelection.section == .plot
    }

    private var showsWorldbuildingActions: Bool {
        appState.workspaceSelection.section == .worldbuilding
    }

    private var showsReferenceActions: Bool {
        appState.workspaceSelection.section == .references
    }

    private var selectedPlotChapterID: ChapterID? {
        guard case let .chapter(chapterID) = appState.plotOutlineSelection else { return nil }
        return chapterID
    }

    private func isPresented(_ overlay: WorkbenchOverlay) -> Binding<Bool> {
        Binding(
            get: { overlayState.presented == overlay },
            set: { isPresented in
                if isPresented {
                    overlayState.presented = overlay
                } else if overlayState.presented == overlay {
                    overlayState.presented = nil
                }
            }
        )
    }
}

enum WorkbenchToolbarItemID {
    static let episodeAdd = "workbench.episode.add"
    static let chapterAdd = "workbench.chapter.add"
    static let chapterMemo = "workbench.chapter.memo"
    static let snapshotSave = "workbench.snapshot.save"
    static let characterAdd = "workbench.character.add"
    static let worldNoteAdd = "workbench.world.note.add"
    static let plotCardAdd = "workbench.plot.card.add"
    static let attachmentAdd = "workbench.attachment.add"
}

enum WorkbenchOverlay: Hashable {
    case memo
    case snapshots
}

@MainActor
@Observable
final class WorkbenchOverlayState {
    var presented: WorkbenchOverlay?

    func toggle(_ overlay: WorkbenchOverlay) {
        presented = presented == overlay ? nil : overlay
    }
}

struct ChapterMemoPopover: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("話メモ")
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

struct SnapshotPopover: View {
    @Environment(AppState.self) private var appState
    @Environment(SnapshotMenuPresenter.self) private var presenter

    let overlayState: WorkbenchOverlayState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("スナップショット")
                    .font(.headline)
                Spacer()
                Button {
                    Task {
                        _ = await appState.createSnapshot()
                        await presenter.refresh()
                    }
                } label: {
                    Label("保存", systemImage: "plus")
                }
                .labelStyle(.iconOnly)
                .help("現在の状態を保存")
            }

            Divider()

            if presenter.snapshots.isEmpty {
                ContentUnavailableView(
                    "スナップショットがありません",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("保存ボタンから現在の状態を記録できます。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(presenter.snapshots) { snapshot in
                    HStack(spacing: 8) {
                        Button(snapshot.displayName) {
                            presenter.snapshotPendingRestore = snapshot
                            overlayState.presented = nil
                        }
                        .buttonStyle(.plain)
                        .lineLimit(1)

                        Spacer()

                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([snapshot.url])
                        } label: {
                            Label("Finderで表示", systemImage: "folder")
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Finderで表示")
                    }
                }
                .listStyle(.plain)
            }
        }
        .padding(12)
        .task {
            await presenter.refresh()
        }
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
        chapterID ?? appState.selectedChapterID
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
