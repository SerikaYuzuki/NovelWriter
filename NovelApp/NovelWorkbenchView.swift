import EditorKit
import NovelCore
import SwiftUI
import UniformTypeIdentifiers

/// 3列ワークベンチのルート(docs/TOOLBAR.md Toolbar-1 / Toolbar-2)。
///
/// `NavigationSplitView` で Project Sidebar / Outline(content) / Detail を構成し、
/// 標準の Sidebar 開閉と列追従 chrome を得る。下部の AI Assistant Panel は
/// 従来どおり split の外に置く。上部 chrome は `WorkbenchToolbarContent` が一箇所で所有する。
private struct WorkbenchColumnWidths {
    var min: CGFloat
    var ideal: CGFloat
    var max: CGFloat
}

struct NovelWorkbenchView: View {
    @Environment(AppState.self) private var appState
    @Environment(EditorSettings.self) private var editorSettings
    @Environment(EditorSearchSession.self) private var editorSearchSession
    @Environment(SnapshotMenuPresenter.self) private var snapshotMenuPresenter

    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var selectedAttachmentFileName: String?
    @State private var sectionOverviewSelection: String? = Self.overviewItemID
    @State private var overlayState = WorkbenchOverlayState()
    @State private var isImportingAttachment = false
    @State private var attachmentImportMessage: OperationMessage?

    fileprivate static let overviewItemID = "overview"

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                ProjectSidebarView()
                    .navigationSplitViewColumnWidth(min: 184, ideal: 200, max: 224)
            } content: {
                workbenchContent
                    .navigationSplitViewColumnWidth(
                        min: contentColumnWidths.min,
                        ideal: contentColumnWidths.ideal,
                        max: contentColumnWidths.max
                    )
            } detail: {
                workbenchDetail
                    .frame(minWidth: 560)
            }

            AIAssistantPanelView()
        }
        .preferredColorScheme(.dark)
        .toolbar(id: "novelwriter.workbench.v1") {
            WorkbenchToolbarContent(
                overlayState: overlayState,
                showsWritingActions: showsWritingActions,
                onOpenCharacter: openCharacter,
                onOpenPlotCard: openPlotCard
            )
        }
        .searchable(
            text: Bindable(editorSearchSession).query,
            isPresented: searchableIsPresented,
            placement: .toolbar,
            prompt: "話内を検索"
        )
        .onSubmit(of: .search) {
            editorSearchSession.jump(direction: .forward, in: appState.selectedEpisode)
        }
        .onChange(of: showsWritingActions) { _, isWriting in
            editorSearchSession.isSearchPresented = isWriting
        }
        .background {
            Button("AI Assistant") {
                appState.aiAssistantPanel.isExpanded.toggle()
            }
            .keyboardShortcut("j", modifiers: .command)
            .hidden()
        }
        .onChange(of: appState.workspaceSelection.section) { _, _ in
            // 概要リストはセクションごとに付け替える。資料選択は AppState 外の
            // 一時状態だが、登場人物選択と同様に戻ってきたときに残す。
            sectionOverviewSelection = Self.overviewItemID
        }
        .confirmationDialog(
            "このスナップショットに戻しますか？",
            isPresented: snapshotRestoreDialogIsPresented,
            presenting: snapshotMenuPresenter.snapshotPendingRestore
        ) { snapshot in
            Button("戻す", role: .destructive) {
                Task { await snapshotMenuPresenter.restore(snapshot) }
            }
            Button("キャンセル", role: .cancel) {}
        } message: { snapshot in
            Text("「\(snapshot.displayName)」の状態に戻します。いまの内容は先にスナップショットへ退避します。")
        }
        .alert(
            "復元できませんでした",
            isPresented: snapshotRestoreErrorIsPresented
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(snapshotMenuPresenter.restoreErrorMessage ?? "")
        }
        .alert(item: $attachmentImportMessage) { message in
            Alert(title: Text(message.title), message: Text(message.body), dismissButton: .default(Text("閉じる")))
        }
        .fileImporter(
            isPresented: $isImportingAttachment,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            Task {
                await importAttachment(from: result)
            }
        }
        .task(id: appState.documentURL) {
            await snapshotMenuPresenter.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .presentChapterMemo)) { _ in
            guard appState.selectedEpisode != nil else { return }
            overlayState.presented = .memo
        }
        .onReceive(NotificationCenter.default.publisher(for: .presentAttachmentImporter)) { _ in
            guard appState.supportsAttachments else { return }
            appState.selectProjectSection(.references)
            isImportingAttachment = true
        }
    }

    private var searchableIsPresented: Binding<Bool> {
        Binding(
            get: { showsWritingActions && editorSearchSession.isSearchPresented },
            set: { newValue in
                guard showsWritingActions else { return }
                editorSearchSession.isSearchPresented = newValue
            }
        )
    }

    private var snapshotRestoreDialogIsPresented: Binding<Bool> {
        Binding(
            get: { snapshotMenuPresenter.snapshotPendingRestore != nil },
            set: { isPresented in
                if !isPresented {
                    snapshotMenuPresenter.snapshotPendingRestore = nil
                }
            }
        )
    }

    private var snapshotRestoreErrorIsPresented: Binding<Bool> {
        Binding(
            get: { snapshotMenuPresenter.restoreErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    snapshotMenuPresenter.restoreErrorMessage = nil
                }
            }
        )
    }

    private func openCharacter(_ characterID: CharacterID) {
        appState.selectCharacter(characterID)
        appState.selectProjectSection(.characters)
    }

    private func openPlotCard(_ cardID: PlotCardID) {
        appState.selectPlotCard(cardID)
        appState.selectProjectSection(.plot)
    }

    @MainActor
    private func importAttachment(from result: Result<[URL], Error>) async {
        do {
            guard let sourceURL = try result.get().first else { return }
            let didAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            if let attachment = await appState.addAttachment(from: sourceURL) {
                selectedAttachmentFileName = attachment.fileName
                attachmentImportMessage = OperationMessage(title: "取り込みました", body: attachment.fileName)
            } else {
                attachmentImportMessage = OperationMessage(title: "取り込めませんでした", body: "資料の追加に失敗しました。")
            }
        } catch {
            attachmentImportMessage = OperationMessage(title: "取り込めませんでした", body: String(describing: error))
        }
    }

    @ViewBuilder
    private var workbenchContent: some View {
        switch appState.workspaceSelection.section {
        case .structure:
            OutlineContainerView()
                .navigationTitle(documentDisplayTitle)
                .navigationSubtitle("\(appState.document.chapters.count)章")
        case .characters:
            CharacterListView()
                .navigationTitle("登場人物")
        case .plot:
            PlotChapterOutlineView()
                .navigationTitle("プロット")
        case .references:
            AttachmentListView(selection: $selectedAttachmentFileName)
                .navigationTitle("資料")
        case .projectInfo, .worldbuilding, .settings:
            SectionOverviewList(
                section: appState.workspaceSelection.section,
                selection: $sectionOverviewSelection
            )
            .navigationTitle(appState.workspaceSelection.section.title)
        }
    }

    @ViewBuilder
    private var workbenchDetail: some View {
        switch appState.workspaceSelection.section {
        case .structure:
            EditorPaneView()
        case .characters:
            CharacterDetailView { appearance in
                appState.selectProjectSection(.structure)
                appState.selectEpisode(appearance.episodeID, in: appearance.chapterID)
                editorSearchSession.requestSelection(range: appearance.range)
            }
        case .plot:
            PlotAndFlagSplitView { chapterID in
                appState.selectProjectSection(.structure)
                appState.selectChapter(chapterID)
            }
        case .references:
            AttachmentDetailView(fileName: selectedAttachmentFileName)
        case .projectInfo:
            ProjectInfoView()
        case .worldbuilding:
            NotesSectionView(
                title: "世界観",
                systemImage: "globe.asia.australia",
                placeholder: "世界観メモは今後の保存モデル追加で有効化します。"
            )
        case .settings:
            SectionSurface(title: "設定", systemImage: "gearshape") {
                EditorSettingsView()
                    .environment(editorSettings)
                    .frame(maxWidth: 560, alignment: .leading)
            }
        }
    }

    private var showsWritingActions: Bool {
        appState.workspaceSelection.section == .structure
    }

    private var documentDisplayTitle: String {
        let trimmed = appState.document.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "無題の作品" : trimmed
    }

    private var contentColumnWidths: WorkbenchColumnWidths {
        switch appState.workspaceSelection.section {
        case .structure:
            WorkbenchColumnWidths(min: 224, ideal: 360, max: 440)
        case .plot:
            WorkbenchColumnWidths(min: 224, ideal: 360, max: 440)
        case .characters, .references:
            WorkbenchColumnWidths(min: 240, ideal: 280, max: 340)
        case .projectInfo, .worldbuilding, .settings:
            WorkbenchColumnWidths(min: 200, ideal: 240, max: 280)
        }
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
        .workbenchGlassOutlineStyle()
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

/// 永続モデルがまだないセクション用の content 列。detail に概要を出す。
private struct SectionOverviewList: View {
    let section: ProjectSection
    @Binding var selection: String?

    var body: some View {
        List(selection: $selection) {
            VStack(alignment: .leading, spacing: 4) {
                Label("概要", systemImage: section.systemImage)
                Text("\(section.title)の概要")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .tag(NovelWorkbenchView.overviewItemID)
        }
        .workbenchGlassOutlineStyle()
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
    @Environment(EditorSearchSession.self) private var editorSearchSession

    var body: some View {
        HStack(spacing: 8) {
            Button {
                appState.aiAssistantPanel.isExpanded.toggle()
            } label: {
                statusContent
            }
            .buttonStyle(.plain)

            if appState.saveState == .failed {
                Button("再試行") {
                    appState.retrySave()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.trailing, 8)
            }
        }
        .background(.bar)
    }

    private var statusContent: some View {
        HStack(spacing: 16) {
            Label(appState.saveState.label, systemImage: appState.saveState.systemImage)
            Text(chapterCountText)
            Text(totalCountText)
            if appState.workspaceSelection.section == .structure, editorSearchSession.didMissSearch {
                Text("見つかりません")
            }
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

    private var chapterCountText: String {
        let count = ManuscriptMetrics.countCharacters(in: appState.selectedEpisode?.content ?? "")
        return "話 \(count)字"
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
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox("編集") {
                        VStack(alignment: .leading, spacing: 8) {
                            WorkbenchLabeledField("作品タイトル") {
                                TextField("作品タイトル", text: titleBinding)
                            }

                            WorkbenchLabeledEditor("あらすじ") {
                                TextEditor(text: synopsisBinding)
                                    .accessibilityLabel("あらすじ")
                                    .frame(minHeight: 160)
                            }
                        }
                        .padding(8)
                    }

                    GroupBox("保存情報") {
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent("保存場所") {
                                Text(appState.documentURL.path)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                    .multilineTextAlignment(.trailing)
                            }
                            LabeledContent("保存状態", value: appState.saveState.label)
                            LabeledContent("章数") {
                                Text("\(appState.document.chapters.count)")
                                    .monospacedDigit()
                            }
                            LabeledContent("話数") {
                                Text("\(episodeCount)")
                                    .monospacedDigit()
                            }
                            LabeledContent("文字数") {
                                Text("\(appState.document.manuscriptCharacterCount)")
                                    .monospacedDigit()
                            }
                            LabeledContent("保存形式", value: ".novelpkg v3")
                        }
                        .padding(8)
                    }
                }
                .padding(20)
                .frame(maxWidth: 720, alignment: .leading)
            }
        }
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: { appState.document.title },
            set: { appState.updateDocumentTitle($0) }
        )
    }

    private var synopsisBinding: Binding<String> {
        Binding(
            get: { appState.document.synopsis },
            set: { appState.updateDocumentSynopsis($0) }
        )
    }

    private var episodeCount: Int {
        appState.document.chapters.reduce(0) { $0 + $1.episodes.count }
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

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .workbenchGlassChromeStyle()
    }
}
