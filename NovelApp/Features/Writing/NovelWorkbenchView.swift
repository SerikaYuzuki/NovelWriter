import EditorKit
import NovelCore
import NovelTextAnalysis
import NovelThumbnail
import NovelUI
import NovelWorkspace
import NovelWorkspaceUI
import SwiftUI
import UniformTypeIdentifiers

/// セクションに応じて2列または3列となるワークベンチのルート(docs/TOOLBAR.md Toolbar-1 / Toolbar-2)。
///
/// Outlineを持つセクションは Project Sidebar / Outline(content) / Detail、作品情報と設定は
/// Project Sidebar / Detail で構成する。標準の Sidebar 開閉と列追従 chrome を得る。
/// 執筆画面の保存・同期状態はEditor上端の小さな記号へ集約する。上部 chrome は
/// detailがカスタマイズを所有し、Outlineの追加操作は列scopeを保って提供する。
private struct WorkbenchColumnWidths {
    var min: CGFloat
    var ideal: CGFloat
    var max: CGFloat
}

enum WorkbenchColumnLayout: Hashable {
    case twoColumn
    case threeColumn

    init(section: ProjectSection) {
        switch section {
        case .projectInfo, .settings:
            self = .twoColumn
        case .structure, .plot, .characters, .worldbuilding, .references, .feedback:
            self = .threeColumn
        }
    }
}

struct NovelWorkbenchView: View {
    @Environment(AppState.self) private var appState
    @Environment(EditorSettings.self) private var editorSettings
    @Environment(EditorSearchSession.self) private var editorSearchSession

    @State private var episodePendingRename: EpisodeRenameRequest?
    @State private var explicitSyncPresentation = ExplicitSyncPresentation()
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var selectedAttachmentFileName: String?
    @State private var selectedFeedbackID: UUID?
    @State private var overlayState = WorkbenchOverlayState()
    @State private var isImportingAttachment = false
    @State private var attachmentImportSession: WorkspaceSessionToken?
    @State private var attachmentImportMessage: OperationMessage?
    @State private var isPlotCardRailPresented = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAssistantPresented = false
    @FocusState private var projectSidebarIsFocused: Bool

    var body: some View {
        ResizableAssistantLayout(isPresented: isAssistantPresented && showsWritingActions, defaults: appState.userDefaults) {
            VStack(spacing: 0) {
                workbenchSplitView
                if !showsWritingActions {
                    WorkbenchStatusBarView()
                }
            }
            .frame(minHeight: 240)
        } panel: {
            assistantPanel
        }
        .overlay(alignment: .bottom) {
            if let notice = appState.manuscriptCopyNotice {
                ManuscriptCopyNoticeView(notice: notice, onDismiss: appState.dismissManuscriptCopyNotice)
                    .padding()
            }
        }
        .animation(Motion.standard(reduceMotion: reduceMotion), value: isAssistantPresented)
        .modifier(WritingSyncPulse(host: appState.writingAssistantHost))
        .navigationTitle(documentDisplayTitle)
        .modifier(WorkbenchToolbarTitleVisibility())
        .modifier(EpisodeRenameDialog(request: $episodePendingRename))
        .modifier(ExplicitSyncSetupModifier(presentation: explicitSyncPresentation))
        .modifier(SnapshotSyncObservationModifier())
        .onReceive(NotificationCenter.default.publisher(for: .toggleWritingAssistant)) { _ in
            if showsWritingActions {
                isAssistantPresented.toggle()
            }
        }
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbarBackground(Color(nsColor: .underPageBackgroundColor), for: .windowToolbar)
        .onChange(of: showsWritingActions) { _, isWriting in
            if !isWriting {
                isPlotCardRailPresented = false
                isAssistantPresented = false
            }
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
        .onReceive(NotificationCenter.default.publisher(for: .presentChapterMemo)) { _ in
            guard appState.selectedEpisode != nil else { return }
            overlayState.presented = .memo
        }
        .onReceive(NotificationCenter.default.publisher(for: .presentAttachmentImporter)) { _ in
            guard appState.supportsAttachments else { return }
            Task {
                guard await appState.selectProjectSectionAfterTransition(.references) else { return }
                attachmentImportSession = appState.documentSessionToken
                isImportingAttachment = true
            }
        }
    }

    private var assistantPanel: some View {
        let session = appState.documentSessionToken
        let episodeID = appState.selectedEpisodeID
        let account = appState.snapshotSyncV2AccountScopeToken
        return AssistantPanelView(
            defaults: appState.userDefaults,
            contextID: "\(appState.documentSessionToken)-\(String(describing: appState.selectedEpisodeID))-\(appState.snapshotSyncV2AccountScopeToken)",
            episodeTitle: appState.selectedEpisode?.title ?? "未選択",
            currentEpisodeID: episodeID,
            capture: {
                guard appState.permitsDocumentInteraction, let episode = appState.selectedEpisode else {
                    throw AssistantError.emptyContent
                }
                switch appState.activeCommittedTextCapture() {
                case let .captured(text): return AssistantManuscript(title: episode.title, content: text)
                case .compositionInProgress: throw AssistantError.composing
                case .notActive: return AssistantManuscript(title: episode.title, content: episode.content)
                }
            }, close: { isAssistantPresented = false },
            applyProofreading: { manuscript, replacement in
                guard appState.documentSessionToken == session,
                      appState.selectedEpisodeID == episodeID,
                      appState.snapshotSyncV2AccountScopeToken == account,
                      appState.permitsDocumentInteraction else { return false }
                return appState.writingProgress.withUncountedEditorChange {
                    appState.editorCommandSession.applyProofreading(expectedText: manuscript.content, replacement: replacement)
                }
            },
            saveFeedback: { feedback in
                await appState.saveAssistantFeedback(feedback, session: session, account: account)
            },
            writingHost: appState.writingAssistantHost,
            chapters: appState.document.chapters,
            document: appState.document,
            captureScope: { scope in
                guard appState.documentSessionToken == session,
                      appState.snapshotSyncV2AccountScopeToken == account,
                      appState.permitsDocumentInteraction else { throw AssistantError.emptyContent }
                return try scope.capture(chapters: appState.document.chapters, currentID: appState.selectedEpisodeID) {
                    guard let episode = appState.selectedEpisode else { throw AssistantError.emptyContent }
                    switch appState.activeCommittedTextCapture() {
                    case let .captured(text): return AssistantManuscript(title: episode.title, content: text)
                    case .compositionInProgress: throw AssistantError.composing
                    case .notActive: return AssistantManuscript(title: episode.title, content: episode.content)
                    }
                }
            }
        )
    }

    private var workbenchSplitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            projectSidebar
        } content: {
            workbenchContent
                .toolbar { WorkbenchOutlineToolbarContent(requestEpisodeRename: requestEpisodeRename) }
                .navigationSplitViewColumnWidth(
                    min: contentColumnWidths.min,
                    ideal: contentColumnWidths.ideal,
                    max: contentColumnWidths.max
                )
        } detail: {
            workbenchDetail
                .frame(minWidth: 560)
        }
    }

    private var projectSidebar: some View {
        ProjectSidebarView(
            isFocused: $projectSidebarIsFocused,
            onSelect: selectProjectSectionFromSidebar
        )
        .navigationSplitViewColumnWidth(min: 184, ideal: 200, max: 224)
        .background(WorkbenchContentColumnVisibility(isCollapsed: usesTwoColumnLayout))
    }

    private func selectProjectSectionFromSidebar(_ section: ProjectSection) {
        Task { @MainActor in
            guard await appState.selectProjectSectionAfterTransition(section) else { return }
            // The sidebar survives section changes; retain keyboard navigation on the clicked list.
            projectSidebarIsFocused = true
        }
    }

    @MainActor
    private func importAttachment(from result: Result<[URL], Error>) async {
        let expectedSession = attachmentImportSession
        attachmentImportSession = nil
        guard let expectedSession else {
            attachmentImportMessage = OperationMessage(
                title: "取り込めませんでした",
                body: "作品を確認できないため、資料を変更していません。もう一度お試しください。"
            )
            return
        }

        do {
            guard let sourceURL = try result.get().first else { return }
            let didAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            let attachment = await appState.addAttachment(
                from: sourceURL,
                expectedSession: expectedSession
            )
            guard appState.documentSessionToken == expectedSession else {
                attachmentImportMessage = OperationMessage(
                    title: attachment == nil ? "取り込みませんでした" : "元の作品に取り込みました",
                    body: "操作中に別の作品へ切り替わりました。現在の資料は変更していません。"
                )
                return
            }

            if let attachment {
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
            if appState.workSearch.isPresented {
                MacWorkSearchView()
            } else {
                OutlineContainerView()
            }
        case .characters:
            CharacterListView()
                .navigationTitle("登場人物")
        case .plot:
            PlotChapterOutlineView()
                .navigationTitle("プロット")
        case .feedback:
            MacAssistantFeedbackOutline(selection: $selectedFeedbackID)
        case .references:
            AttachmentListView(selection: $selectedAttachmentFileName)
                .navigationTitle("資料")
        case .worldbuilding:
            WorldbuildingOutlineView()
                .navigationTitle(appState.workspaceSelection.section.title)
        case .projectInfo, .settings:
            EmptyView()
        }
    }

    private var workbenchDetail: some View {
        workbenchDetailContent
            .background {
                WorkbenchToolbarPersistence(profile: appState.workspaceSelection.section.rawValue)
                    .id(appState.workspaceSelection.section)
                    .frame(width: 0, height: 0)
            }
            .toolbar(id: WorkbenchToolbarIdentity.current) {
                WorkbenchToolbarContent(
                    overlayState: overlayState,
                    requestSync: { explicitSyncPresentation.requestSync(appState: appState) },
                    showsWritingActions: showsWritingActions,
                    isPlotCardRailPresented: $isPlotCardRailPresented,
                    requestEpisodeRename: requestEpisodeRename
                )
            }
    }

    private func requestEpisodeRename() {
        guard let episode = appState.selectedEpisode, let chapterID = appState.selectedChapterID else { return }
        episodePendingRename = EpisodeRenameRequest(episode: episode, chapterID: chapterID, appState: appState)
    }

    @ViewBuilder
    private var workbenchDetailContent: some View {
        switch appState.workspaceSelection.section {
        case .structure:
            VStack(spacing: 0) {
                HStack {
                    Text(documentDisplayTitle)
                        .accessibilityIdentifier("workbench.editor.workTitle")
                        .font(.headline)
                        .foregroundStyle((Color(hex: editorSettings.textColorHex) ?? .primary).opacity(0.75))
                        .lineLimit(1)
                        .help(documentDisplayTitle)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(hex: editorSettings.backgroundColorHex) ?? Color(nsColor: .textBackgroundColor))
                .overlay(alignment: .bottom) { Divider() }
                EditorPaneView(isPlotCardRailPresented: $isPlotCardRailPresented)
            }
        case .characters:
            CharacterDetailView { appearance in
                let scope = appState.workSearchScope
                Task {
                    guard appState.workSearchScope == scope, await appState.selectProjectSectionAfterTransition(.structure),
                          appState.workSearchScope == scope else { return }
                    guard await appState.selectEpisodeAfterTransition(
                        appearance.episodeID,
                        in: appearance.chapterID
                    ) else { return }
                    guard appState.workSearchScope == scope,
                          let current = appState.document.episode(appearance.episodeID)?.episode.content,
                          WorkTextSearch.sameText(current, appearance.source) else { return }
                    editorSearchSession.requestSelection(range: appearance.range, episodeID: appearance.episodeID)
                }
            }
        case .plot:
            PlotAndFlagSplitView { chapterID in
                Task {
                    guard await appState.selectProjectSectionAfterTransition(.structure) else { return }
                    await appState.selectChapterAfterTransition(chapterID)
                }
            }
        case .feedback:
            AssistantFeedbackDetail(record: appState.assistantFeedback.first { $0.id == selectedFeedbackID })
        case .references:
            AttachmentDetailView(fileName: selectedAttachmentFileName)
        case .projectInfo:
            ProjectInfoView()
        case .worldbuilding:
            WorldNoteDetailView()
        case .settings:
            SectionSurface(title: "設定", systemImage: "gearshape") {
                EditorSettingsView()
                    .environment(editorSettings)
            }
        }
    }

    private var showsWritingActions: Bool {
        appState.workspaceSelection.section == .structure
    }

    private var usesTwoColumnLayout: Bool {
        workbenchColumnLayout == .twoColumn
    }

    private var workbenchColumnLayout: WorkbenchColumnLayout {
        WorkbenchColumnLayout(section: appState.workspaceSelection.section)
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
        case .characters, .references, .feedback:
            WorkbenchColumnWidths(min: 240, ideal: 280, max: 340)
        case .worldbuilding:
            WorkbenchColumnWidths(min: 200, ideal: 240, max: 280)
        case .projectInfo, .settings:
            // 2列セクションでは content 列を出さないため未使用
            WorkbenchColumnWidths(min: 200, ideal: 240, max: 280)
        }
    }
}

struct ProjectSidebarView: View {
    @Environment(AppState.self) private var appState

    let isFocused: FocusState<Bool>.Binding
    let onSelect: (ProjectSection) -> Void

    var body: some View {
        List(selection: sectionSelection) {
            Section("この作品") {
                ForEach(ProjectSection.allCases.filter { $0 != .settings }) { section in
                    if section == .plot {
                        section.style.label
                            .badge(appState.document.flags.count(where: { !$0.isResolved }))
                            .tag(section)
                    } else {
                        section.style.label.tag(section)
                    }
                }
            }
            Section("アプリ") {
                ProjectSection.settings.style.label.tag(ProjectSection.settings)
            }
        }
        .focused(isFocused)
        .workbenchGlassOutlineStyle()
    }

    private var sectionSelection: Binding<ProjectSection?> {
        Self.selectionBinding(appState: appState, onSelect: onSelect)
    }

    static func selectionBinding(appState: AppState, onSelect: @escaping (ProjectSection) -> Void) -> Binding<ProjectSection?> {
        Binding(
            get: { appState.workspaceSelection.section },
            set: { section in
                if let section {
                    onSelect(section)
                }
            }
        )
    }
}

/// 世界観ノートの一覧Outline。並び順はNovelDocument.worldNotesの配列順を正とする。
private struct WorldbuildingOutlineView: View {
    @Environment(AppState.self) private var appState

    @State private var notePendingDeletion: SessionBoundValue<WorldNote>?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selectionBinding) {
                ForEach(sessionBoundWorldNotes) { item in
                    HStack(spacing: Spacing.small) {
                        ThumbnailImage(data: appState.thumbnailData(ThumbnailOwner(.worldNote, item.value.id.rawValue)), kind: .worldNote, title: item.value.title, size: 28).accessibilityHidden(true)
                        WorldNoteRow(note: item.value)
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            notePendingDeletion = item
                        } label: {
                            Label("削除", systemImage: "trash")
                        }
                    }
                    .tag(item.value.id)
                }
                .onMove { offsets, destination in
                    appState.moveWorldNotes(fromOffsets: offsets, toOffset: destination)
                }
            }
            .overlay {
                if appState.document.worldNotes.isEmpty {
                    ContentUnavailableView {
                        Label("世界観ノートがありません", systemImage: "globe.asia.australia")
                    } actions: {
                        Button("ノートを追加") { appState.addWorldNote() }
                            .disabled(!appState.permitsDocumentInteraction)
                    }
                }
            }
            .workbenchGlassOutlineStyle()
        }
        .onDeleteCommand {
            guard let note = appState.selectedWorldNote else { return }
            notePendingDeletion = SessionBoundValue(
                value: note,
                session: appState.documentSessionToken
            )
        }
        .confirmationDialog(
            "世界観ノートを削除しますか？",
            isPresented: noteDeletionDialogIsPresented,
            presenting: notePendingDeletion
        ) { request in
            Button("削除", role: .destructive) {
                appState.deleteWorldNote(id: request.value.id, expectedSession: request.session)
            }
            Button("キャンセル", role: .cancel) {}
        } message: { request in
            Text("「\(displayTitle(for: request.value))」を削除します。")
        }
    }

    private var sessionBoundWorldNotes: [SessionBoundValue<WorldNote>] {
        let session = appState.documentSessionToken
        return appState.document.worldNotes.map {
            SessionBoundValue(value: $0, session: session)
        }
    }

    private var selectionBinding: Binding<WorldNoteID?> {
        Binding(
            get: { appState.selectedWorldNoteID },
            set: { appState.selectWorldNote($0) }
        )
    }

    private var noteDeletionDialogIsPresented: Binding<Bool> {
        Binding(
            get: { notePendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    notePendingDeletion = nil
                }
            }
        )
    }

    private func displayTitle(for note: WorldNote) -> String {
        let trimmed = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "無題のノート" : trimmed
    }
}

private struct WorldNoteRow: View {
    let note: WorldNote

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(displayTitle)
                .lineLimit(1)
            Text("\(ManuscriptCountCache.shared.count(note))字")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(displayTitle)、\(ManuscriptCountCache.shared.count(note))字")
    }

    private var displayTitle: String {
        let trimmed = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "無題のノート" : trimmed
    }
}

private struct WorldNoteDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(EditorSettings.self) private var editorSettings
    @Environment(EditorCommandSession.self) private var editorCommandSession

    var body: some View {
        Group {
            if let note = appState.selectedWorldNote {
                let session = appState.documentSessionToken
                VStack(alignment: .leading, spacing: 16) {
                    MacThumbnailEditor(owner: ThumbnailOwner(.worldNote, note.id.rawValue), title: note.title)
                    WorkbenchLabeledField("タイトル") {
                        TextField("ノートのタイトル", text: titleBinding(for: note))
                            .textFieldStyle(.roundedBorder)
                    }

                    ZStack {
                        Color(hex: editorSettings.backgroundColorHex) ?? Color(nsColor: .textBackgroundColor)
                        EditorView(
                            chapterKey: SessionBoundEditorKey(
                                value: note.id,
                                generation: appState.editorContentGeneration
                            ),
                            initialText: note.content,
                            commandSession: editorCommandSession,
                            configuration: editorSettings.configuration,
                            onTextChange: { content in
                                appState.updateWorldNoteContent(
                                    content,
                                    for: note.id,
                                    expectedSession: session
                                )
                            }
                        )
                        .frame(maxWidth: editorMaximumWidth)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(20)
            } else {
                ContentUnavailableView {
                    Label("世界観ノートが選択されていません", systemImage: "globe.asia.australia")
                } description: {
                    if !appState.document.worldNotes.isEmpty {
                        Text("左の一覧から世界観ノートを選択してください。")
                    }
                }
            }
        }
        .workbenchGlassChromeStyle()
    }

    private func titleBinding(for note: WorldNote) -> Binding<String> {
        Binding(
            get: { noteTitle(for: note.id) },
            set: { appState.updateWorldNoteTitle($0, for: note.id) }
        )
    }

    private func noteTitle(for id: WorldNoteID) -> String {
        appState.document.worldNotes.first(where: { $0.id == id })?.title ?? ""
    }

    private var editorMaximumWidth: CGFloat? {
        editorSettings.widthMode.maximumContentWidth.map { CGFloat($0) }
    }
}

private struct WorkbenchStatusBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(EditorSearchSession.self) private var editorSearchSession

    var body: some View {
        statusContent
            .background(.bar)
    }

    private var statusContent: some View {
        HStack(spacing: 16) {
            Text(chapterCountText)
            Text(totalCountText)
            if appState.workspaceSelection.section == .structure, editorSearchSession.didMissSearch {
                Text("見つかりません")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .padding(.horizontal, 12)
        .frame(height: 28)
        .accessibilityElement(children: .combine)
    }

    private var chapterCountText: String {
        let count = ManuscriptMetrics.countCharacters(in: appState.selectedEpisode?.content ?? "")
        return "話 \(count)字"
    }

    private var totalCountText: String {
        "全体 \(ManuscriptCountCache.shared.count(appState.document))字"
    }
}

private struct ProjectInfoView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        SectionSurface(title: "作品情報", systemImage: "book.closed") {
            Form {
                Section {
                    HStack(alignment: .top, spacing: Spacing.outer) {
                        MacThumbnailEditor(owner: ThumbnailOwner(.work, appState.document.id), title: appState.document.title)
                        WorkInfoSummary(document: appState.document, showsCover: false)
                    }
                    WritingProgressCard(tracker: appState.writingProgress)
                }
                Section("編集") {
                    TextField("作品タイトル", text: titleBinding, axis: .vertical).lineLimit(1 ... 3)
                }
                Section("あらすじ") {
                    TextEditor(text: synopsisBinding).japaneseTextEditorStyle()
                        .accessibilityLabel("あらすじ")
                        .frame(minHeight: 160, idealHeight: 280)
                }
            }
            .formStyle(.grouped)
            .background(FuminiwaColor.paper.color)
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
        .background(FuminiwaColor.paper.color)
    }
}

private struct WorkbenchToolbarTitleVisibility: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.toolbar(removing: .title)
        } else {
            content.navigationTitle("")
        }
    }
}
