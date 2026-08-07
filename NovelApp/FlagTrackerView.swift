import NovelCore
import NovelUI
import SwiftUI

/// プロットdetail下段の伏線領域。選択状態はAppStateに集約したまま一覧と詳細を分ける。
struct FlagSectionView: View {
    @Environment(AppState.self) private var appState

    let onChapterJump: (ChapterID) -> Void

    @State private var flagPendingDeletion: SessionBoundValue<Flag>?

    var body: some View {
        HSplitView {
            FlagListView(flagPendingDeletion: $flagPendingDeletion)
                .frame(minWidth: 240, idealWidth: 280)

            FlagDetailView(onChapterJump: onChapterJump)
                .frame(minWidth: 280, idealWidth: 360)
        }
        .confirmationDialog(
            "伏線を削除しますか？",
            isPresented: flagDeletionDialogIsPresented,
            presenting: flagPendingDeletion
        ) { request in
            Button("削除", role: .destructive) {
                appState.deleteFlag(id: request.value.id, expectedSession: request.session)
            }
            Button("キャンセル", role: .cancel) {}
        } message: { request in
            Text("「\(request.value.title)」を削除します。")
        }
    }

    private var flagDeletionDialogIsPresented: Binding<Bool> {
        Binding(
            get: { flagPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    flagPendingDeletion = nil
                }
            }
        )
    }
}

/// UI-REV-2以前の呼び出し互換。新規呼び出しは`FlagSectionView`を使う。
struct FlagTrackerView: View {
    let onChapterJump: (ChapterID) -> Void

    var body: some View {
        FlagSectionView(onChapterJump: onChapterJump)
    }
}

private struct FlagListView: View {
    @Environment(AppState.self) private var appState

    @Binding var flagPendingDeletion: SessionBoundValue<Flag>?
    @State private var showsResolvedFlags = false

    var body: some View {
        VStack(spacing: 0) {
            List(selection: flagSelectionBinding) {
                Section {
                    ForEach(sessionBoundUnresolvedFlags) { item in
                        FlagRow(flag: item.value, plantedTitle: chapterTitle(for: item.value.plantedChapterID))
                            .tag(item.value.id)
                            .contextMenu {
                                deleteButton(for: item)
                            }
                    }
                } header: {
                    Text("未回収 \(unresolvedFlags.count)件")
                        .monospacedDigit()
                }

                DisclosureGroup(isExpanded: $showsResolvedFlags) {
                    ForEach(sessionBoundResolvedFlags) { item in
                        FlagRow(flag: item.value, plantedTitle: chapterTitle(for: item.value.plantedChapterID))
                            .tag(item.value.id)
                            .contextMenu {
                                deleteButton(for: item)
                            }
                    }
                } label: {
                    Text("回収済み \(resolvedFlags.count)件")
                        .monospacedDigit()
                }
            }
            .overlay {
                if appState.document.flags.isEmpty {
                    ContentUnavailableView(
                        "伏線がありません",
                        systemImage: "checklist",
                        description: Text("伏線を追加ボタンから伏線を追加できます。")
                    )
                }
            }

            Divider()

            HStack {
                Button {
                    appState.addFlag()
                } label: {
                    Label("伏線を追加", systemImage: "plus")
                }

                Button(role: .destructive) {
                    flagPendingDeletion = appState.selectedFlag.map {
                        SessionBoundValue(value: $0, session: appState.documentSessionToken)
                    }
                } label: {
                    Label("削除", systemImage: "trash")
                }
                .disabled(appState.selectedFlag == nil)

                Spacer()
            }
            .padding(8)
        }
    }

    private var unresolvedFlags: [Flag] {
        appState.document.flags.filter { !$0.isResolved }
    }

    private var resolvedFlags: [Flag] {
        appState.document.flags.filter(\.isResolved)
    }

    private var sessionBoundUnresolvedFlags: [SessionBoundValue<Flag>] {
        sessionBound(unresolvedFlags)
    }

    private var sessionBoundResolvedFlags: [SessionBoundValue<Flag>] {
        sessionBound(resolvedFlags)
    }

    private var flagSelectionBinding: Binding<FlagID?> {
        Binding(
            get: { appState.selectedFlagID },
            set: { appState.selectFlag($0) }
        )
    }

    private func deleteButton(for item: SessionBoundValue<Flag>) -> some View {
        Button(role: .destructive) {
            flagPendingDeletion = item
        } label: {
            Label("削除", systemImage: "trash")
        }
    }

    private func sessionBound(_ flags: [Flag]) -> [SessionBoundValue<Flag>] {
        let session = appState.documentSessionToken
        return flags.map { SessionBoundValue(value: $0, session: session) }
    }

    private func chapterTitle(for chapterID: ChapterID?) -> String? {
        guard let chapterID else { return nil }
        return appState.document.chapters.first { $0.id == chapterID }?.title
    }
}

private struct FlagDetailView: View {
    @Environment(AppState.self) private var appState

    let onChapterJump: (ChapterID) -> Void

    var body: some View {
        if appState.selectedFlag == nil {
            ContentUnavailableView(
                "伏線が選択されていません",
                systemImage: "checklist",
                description: Text("左の一覧から編集する伏線を選択してください。")
            )
        } else {
            FlagEditor(
                title: selectedFlagTitleBinding,
                note: selectedFlagNoteBinding,
                plantedChapterID: selectedFlagPlantedChapterBinding,
                resolvedChapterID: selectedFlagResolvedChapterBinding,
                isResolved: appState.selectedFlag?.isResolved == true,
                chapters: appState.document.chapters,
                showsOrderWarning: selectedFlagHasOrderWarning,
                onToggleResolved: {
                    appState.toggleSelectedFlagResolved()
                },
                onJump: onChapterJump,
                onCommit: {
                    appState.commitFlagEditing()
                }
            )
        }
    }

    private var selectedFlagTitleBinding: Binding<String> {
        Binding(
            get: { appState.selectedFlag?.title ?? "" },
            set: { appState.updateSelectedFlag(title: $0) }
        )
    }

    private var selectedFlagNoteBinding: Binding<String> {
        Binding(
            get: { appState.selectedFlag?.note ?? "" },
            set: { appState.updateSelectedFlag(note: $0) }
        )
    }

    private var selectedFlagPlantedChapterBinding: Binding<ChapterID?> {
        Binding(
            get: { appState.selectedFlag?.plantedChapterID },
            set: { appState.updateSelectedFlagPlantedChapter($0) }
        )
    }

    private var selectedFlagResolvedChapterBinding: Binding<ChapterID?> {
        Binding(
            get: { appState.selectedFlag?.resolvedChapterID },
            set: { appState.updateSelectedFlagResolvedChapter($0) }
        )
    }

    private var selectedFlagHasOrderWarning: Bool {
        guard let flag = appState.selectedFlag,
              let plantedIndex = chapterIndex(for: flag.plantedChapterID),
              let resolvedIndex = chapterIndex(for: flag.resolvedChapterID) else
        {
            return false
        }

        return resolvedIndex < plantedIndex
    }

    private func chapterIndex(for chapterID: ChapterID?) -> Int? {
        guard let chapterID else { return nil }
        return appState.document.chapters.firstIndex { $0.id == chapterID }
    }
}

private struct FlagEditor: View {
    @Binding var title: String
    @Binding var note: String
    @Binding var plantedChapterID: ChapterID?
    @Binding var resolvedChapterID: ChapterID?

    let isResolved: Bool
    let chapters: [Chapter]
    let showsOrderWarning: Bool
    let onToggleResolved: () -> Void
    let onJump: (ChapterID) -> Void
    let onCommit: () -> Void

    var body: some View {
        Form {
            TextField("タイトル", text: $title)
                .onSubmit(onCommit)

            Button {
                onToggleResolved()
            } label: {
                Label(isResolved ? "未回収に戻す" : "現在章で回収", systemImage: isResolved ? "arrow.uturn.backward" : "checkmark")
            }

            Picker("張った章", selection: $plantedChapterID) {
                chapterPickerOptions()
            }

            Picker("回収章", selection: $resolvedChapterID) {
                chapterPickerOptions()
            }

            HStack {
                Button {
                    if let plantedChapterID {
                        onJump(plantedChapterID)
                    }
                } label: {
                    Label("張った章へ", systemImage: "arrowshape.turn.up.right")
                }
                .disabled(plantedChapterID == nil)

                Button {
                    if let resolvedChapterID {
                        onJump(resolvedChapterID)
                    }
                } label: {
                    Label("回収章へ", systemImage: "arrowshape.turn.up.right")
                }
                .disabled(resolvedChapterID == nil)
            }

            if showsOrderWarning {
                Label("回収章が張った章より前です", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(StyleToken.warning)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("メモ")
                    .foregroundStyle(.secondary)
                TextEditor(text: $note)
                    .frame(minHeight: 160)
            }
        }
        .formStyle(.grouped)
        .padding(8)
        .onDisappear(perform: onCommit)
    }

    @ViewBuilder
    private func chapterPickerOptions() -> some View {
        Text("未設定")
            .tag(nil as ChapterID?)
        ForEach(chapters) { chapter in
            Text(chapter.title)
                .tag(chapter.id as ChapterID?)
        }
    }
}
