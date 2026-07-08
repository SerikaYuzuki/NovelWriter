import NovelCore
import SwiftUI

struct FlagInspectorView: View {
    @Environment(AppState.self) private var appState

    let onChapterJump: (ChapterID) -> Void

    @State private var flagPendingDeletion: Flag?
    @State private var showsResolvedFlags = false

    var body: some View {
        VStack(spacing: 0) {
            List(selection: flagSelectionBinding) {
                Section("未回収 \(unresolvedFlags.count)件") {
                    ForEach(unresolvedFlags) { flag in
                        FlagRow(flag: flag, plantedTitle: chapterTitle(for: flag.plantedChapterID))
                            .tag(flag.id)
                            .contextMenu {
                                deleteButton(for: flag)
                            }
                    }
                }

                DisclosureGroup(isExpanded: $showsResolvedFlags) {
                    ForEach(resolvedFlags) { flag in
                        FlagRow(flag: flag, plantedTitle: chapterTitle(for: flag.plantedChapterID))
                            .tag(flag.id)
                            .contextMenu {
                                deleteButton(for: flag)
                            }
                    }
                } label: {
                    Text("回収済み \(resolvedFlags.count)件")
                }
            }
            .frame(minHeight: 150)

            Divider()

            HStack {
                Button {
                    appState.addFlag()
                } label: {
                    Label("追加", systemImage: "plus")
                }

                Button(role: .destructive) {
                    if let flag = appState.selectedFlag {
                        flagPendingDeletion = flag
                    }
                } label: {
                    Label("削除", systemImage: "trash")
                }
                .disabled(appState.selectedFlag == nil)

                Spacer()
            }
            .padding(10)

            Divider()

            if appState.selectedFlag == nil {
                ContentUnavailableView("伏線が選択されていません", systemImage: "checklist")
                    .frame(maxHeight: .infinity)
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
                    onJump: { chapterID in
                        onChapterJump(chapterID)
                    },
                    onCommit: {
                        appState.commitFlagEditing()
                    }
                )
            }
        }
        .confirmationDialog(
            "伏線を削除しますか？",
            isPresented: flagDeletionDialogIsPresented,
            presenting: flagPendingDeletion
        ) { flag in
            Button("削除", role: .destructive) {
                appState.deleteFlag(id: flag.id)
            }
            Button("キャンセル", role: .cancel) {}
        } message: { flag in
            Text("「\(flag.title)」を削除します。")
        }
    }

    private var unresolvedFlags: [Flag] {
        appState.document.flags.filter { !$0.isResolved }
    }

    private var resolvedFlags: [Flag] {
        appState.document.flags.filter(\.isResolved)
    }

    private var flagSelectionBinding: Binding<FlagID?> {
        Binding(
            get: { appState.selectedFlagID },
            set: { appState.selectFlag($0) }
        )
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

    private func deleteButton(for flag: Flag) -> some View {
        Button(role: .destructive) {
            flagPendingDeletion = flag
        } label: {
            Label("削除", systemImage: "trash")
        }
    }

    private func chapterTitle(for chapterID: ChapterID?) -> String? {
        guard let chapterID else { return nil }
        return appState.document.chapters.first { $0.id == chapterID }?.title
    }

    private func chapterIndex(for chapterID: ChapterID?) -> Int? {
        guard let chapterID else { return nil }
        return appState.document.chapters.firstIndex { $0.id == chapterID }
    }
}

private struct FlagRow: View {
    let flag: Flag
    let plantedTitle: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: flag.isResolved ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(flag.isResolved ? .green : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(NovelDocument.normalizedFlagTitle(flag.title))
                    .lineLimit(1)
                if let plantedTitle {
                    Text(plantedTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
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
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("メモ")
                    .foregroundStyle(.secondary)
                TextEditor(text: $note)
                    .frame(minHeight: 160)
            }
        }
        .formStyle(.grouped)
        .padding(10)
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
