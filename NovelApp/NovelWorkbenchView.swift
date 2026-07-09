import EditorKit
import NovelCore
import SwiftUI

struct NovelWorkbenchView: View {
    @Environment(AppState.self) private var appState
    @Environment(EditorSettings.self) private var editorSettings

    @Binding var searchSelectionRequest: EditorSelectionRequest?

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                ProjectSidebarView()
                    .frame(minWidth: 184, idealWidth: 200, maxWidth: 224)

                detailView
                    .frame(minWidth: 720)
            }

            AIAssistantPanelView()
        }
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItemGroup {
                Spacer()

                if showsWritingActions {
                    Button {
                        appState.addChapter()
                    } label: {
                        Label("章を追加", systemImage: "plus")
                    }
                }
            }
        }
        .background {
            Button("AI Assistant") {
                appState.aiAssistantPanel.isExpanded.toggle()
            }
            .keyboardShortcut("j", modifiers: .command)
            .hidden()
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch appState.workspaceSelection.section {
        case .structure:
            WritingModeView(
                searchSelectionRequest: $searchSelectionRequest,
                onOpenCharacter: { characterID in
                    appState.selectCharacter(characterID)
                    appState.selectProjectSection(.characters)
                },
                onOpenPlotCard: { cardID in
                    appState.selectPlotCard(cardID)
                    appState.selectProjectSection(.plot)
                }
            )
        case .projectInfo:
            ProjectInfoView()
        case .characters:
            CharacterModeView { appearance in
                appState.selectProjectSection(.structure)
                appState.selectChapter(appearance.chapterID)
                searchSelectionRequest = EditorSelectionRequest(range: appearance.range)
            }
        case .plot:
            PlotModeView { chapterID in
                appState.selectProjectSection(.structure)
                appState.selectChapter(chapterID)
            }
        case .planning:
            NotesSectionView(
                title: "企画",
                systemImage: "lightbulb",
                placeholder: "企画メモは今後の保存モデル追加で有効化します。"
            )
        case .worldbuilding:
            NotesSectionView(
                title: "世界観",
                systemImage: "globe.asia.australia",
                placeholder: "世界観メモは今後の保存モデル追加で有効化します。"
            )
        case .references:
            SectionSurface(title: "資料", systemImage: "paperclip") {
                AttachmentInspectorView()
            }
        case .settings:
            SectionSurface(title: "設定", systemImage: "gearshape") {
                EditorSettingsView()
                    .environment(editorSettings)
                    .padding(20)
                    .frame(maxWidth: 560, alignment: .leading)
            }
        }
    }

    private var showsWritingActions: Bool {
        appState.workspaceSelection.section == .structure
    }
}

struct ProjectSidebarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        List(selection: sectionSelection) {
            ForEach(ProjectSection.allCases) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(appState.document.title)
        .scrollContentBackground(.hidden)
        .background(.bar)
    }

    private var sectionSelection: Binding<ProjectSection?> {
        Binding(
            get: { appState.workspaceSelection.section },
            set: { section in
                if let section {
                    appState.selectProjectSection(section)
                }
            }
        )
    }
}

struct AIAssistantPanelView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            AssistantStatusBarView()

            if appState.aiAssistantPanel.isExpanded {
                Divider()
                ResizeHandle()
                expandedContent
                    .frame(height: appState.aiAssistantPanel.height)
            }
        }
        .background(.bar)
    }

    private var expandedContent: some View {
        VStack(spacing: 0) {
            Picker("AI Assistant", selection: selectedTabBinding) {
                ForEach(AIAssistantTab.allCases) { tab in
                    Text(tab.title)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            Divider()

            Group {
                switch appState.aiAssistantPanel.selectedTab {
                case .chat:
                    AssistantChatView()
                case .suggestions:
                    AssistantSuggestionsView()
                case .selectionActions:
                    SelectionActionsView()
                }
            }
        }
    }

    private var selectedTabBinding: Binding<AIAssistantTab> {
        Binding(
            get: { appState.aiAssistantPanel.selectedTab },
            set: { appState.aiAssistantPanel.selectedTab = $0 }
        )
    }
}

private struct ResizeHandle: View {
    @Environment(AppState.self) private var appState

    @State private var dragStartHeight: CGFloat?

    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(height: 6)
            .overlay {
                Capsule()
                    .fill(.secondary.opacity(0.35))
                    .frame(width: 44, height: 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let baseHeight = dragStartHeight ?? appState.aiAssistantPanel.height
                        dragStartHeight = baseHeight
                        let proposedHeight = baseHeight - value.translation.height
                        appState.aiAssistantPanel.height = min(max(proposedHeight, 240), 360)
                    }
                    .onEnded { _ in
                        dragStartHeight = nil
                    }
            )
    }
}

private struct AssistantStatusBarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Button {
            appState.aiAssistantPanel.isExpanded.toggle()
        } label: {
            HStack(spacing: 16) {
                Label("自動保存", systemImage: "checkmark.circle")
                Text(chapterCountText)
                Text(totalCountText)
                Text("行 -- / 列 --")
                Spacer()
                Label("AI 未接続", systemImage: "sparkles")
                Text("通常")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .padding(.horizontal, 12)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var chapterCountText: String {
        let count = ManuscriptMetrics.countCharacters(in: appState.selectedChapter?.content ?? "")
        return "章 \(count)字"
    }

    private var totalCountText: String {
        "全体 \(appState.document.manuscriptCharacterCount)字"
    }
}

private struct AssistantChatView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 8) {
            ContentUnavailableView(
                "AIは未接続です",
                systemImage: "sparkles",
                description: Text("ここにチャットと回答を表示します。")
            )
            TextField("AIに相談", text: inputBinding)
                .textFieldStyle(.roundedBorder)
                .padding([.horizontal, .bottom], 12)
        }
    }

    private var inputBinding: Binding<String> {
        Binding(
            get: { appState.aiAssistantPanel.inputText },
            set: { appState.aiAssistantPanel.inputText = $0 }
        )
    }
}

private struct AssistantSuggestionsView: View {
    var body: some View {
        ContentUnavailableView(
            "提案はありません",
            systemImage: "list.bullet.rectangle",
            description: Text("AI接続後に提案を表示します。")
        )
    }
}

private struct SelectionActionsView: View {
    var body: some View {
        VStack(spacing: 12) {
            ContentUnavailableView(
                "選択中のテキストがありません",
                systemImage: "text.cursor",
                description: Text("本文を選択すると操作を使えます。")
            )
            HStack {
                Button("言い換え") {}
                Button("要約") {}
                Button("矛盾確認") {}
                Button("伏線確認") {}
            }
            .disabled(true)
        }
        .padding()
    }
}

private struct ProjectInfoView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        SectionSurface(title: "作品情報", systemImage: "book.closed") {
            Form {
                LabeledContent("作品タイトル", value: appState.document.title)
                LabeledContent("保存場所", value: appState.documentURL.path)
                LabeledContent("章数", value: "\(appState.document.chapters.count)")
                LabeledContent("文字数", value: "\(appState.document.manuscriptCharacterCount)")
                LabeledContent("保存形式", value: ".novelpkg v2")
            }
            .formStyle(.grouped)
            .padding(20)
            .frame(maxWidth: 720)
        }
    }
}

private struct NotesSectionView: View {
    let title: String
    let systemImage: String
    let placeholder: String

    var body: some View {
        SectionSurface(title: title, systemImage: systemImage) {
            ContentUnavailableView(
                "\(title)は準備中です",
                systemImage: systemImage,
                description: Text(placeholder)
            )
        }
    }
}

private struct SectionSurface<Content: View>: View {
    let title: String
    let systemImage: String
    private let content: Content

    init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
