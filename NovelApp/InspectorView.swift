import NovelCore
import SwiftUI

enum InspectorTab: Hashable {
    case memo
    case characters
    case plot
    case flags
    case attachments
}

struct InspectorView: View {
    let selectedChapter: Chapter?
    @Binding var memo: String
    @Binding var selectedTab: InspectorTab
    let onCharacterSearch: (String) -> Void
    let onCharacterAppearanceJump: (CharacterAppearance) -> Void
    let onPlotChapterJump: (ChapterID) -> Void
    let onFlagChapterJump: (ChapterID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Picker("インスペクタ", selection: $selectedTab) {
                Label("メモ", systemImage: "note.text")
                    .tag(InspectorTab.memo)
                Label("キャラクター", systemImage: "person.2")
                    .tag(InspectorTab.characters)
                Label("プロット", systemImage: "rectangle.stack")
                    .tag(InspectorTab.plot)
                Label("伏線", systemImage: "checklist")
                    .tag(InspectorTab.flags)
                Label("資料", systemImage: "paperclip")
                    .tag(InspectorTab.attachments)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding()

            Divider()

            switch selectedTab {
            case .memo:
                if selectedChapter == nil {
                    ContentUnavailableView("章が選択されていません", systemImage: "note.text")
                } else {
                    TextEditor(text: $memo)
                        .font(.body)
                        .padding(8)
                }
            case .characters:
                CharacterInspectorView(
                    onSearchQuery: onCharacterSearch,
                    onAppearanceJump: onCharacterAppearanceJump
                )
            case .plot:
                PlotInspectorView(onChapterJump: onPlotChapterJump)
            case .flags:
                FlagInspectorView(onChapterJump: onFlagChapterJump)
            case .attachments:
                AttachmentInspectorView()
            }
        }
        .frame(minWidth: 260)
    }
}
