import EditorKit
import NovelCore
import SwiftUI
import UniformTypeIdentifiers

/// セクションに応じて2列または3列となるワークベンチのルート(docs/TOOLBAR.md Toolbar-1 / Toolbar-2)。
///
/// Outlineを持つセクションは Project Sidebar / Outline(content) / Detail、作品情報と設定は
/// Project Sidebar / Detail で構成する。標準の Sidebar 開閉と列追従 chrome を得る。
/// 執筆画面の保存・同期状態はEditor上端の小さな記号へ集約する。上部 chrome は
/// `WorkbenchToolbarContent` が一箇所で所有する。
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
        case .structure, .plot, .characters, .worldbuilding, .references:
            self = .threeColumn
        }
    }

    static func requiresSidebarFocusHandoff(from previous: ProjectSection, to next: ProjectSection) -> Bool {
        WorkbenchColumnLayout(section: previous) != WorkbenchColumnLayout(section: next)
    }
}

struct NovelWorkbenchView: View {
    @Environment(AppState.self) private var appState
    @Environment(EditorSettings.self) private var editorSettings
    @Environment(EditorSearchSession.self) private var editorSearchSession
    @Environment(SnapshotMenuPresenter.self) private var snapshotMenuPresenter
    #if FUMINIWA_ENABLE_EXPERIMENTAL_AI
    @Environment(AIProofreadingOperation.self) private var aiProofreadingOperation
    #endif

    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var selectedAttachmentFileName: String?
    @State private var overlayState = WorkbenchOverlayState()
    @State private var isImportingAttachment = false
    @State private var attachmentImportSession: DocumentSessionToken?
    @State private var attachmentImportMessage: OperationMessage?
    @State private var sidebarFocusHandoffID: UUID?
    @FocusState private var projectSidebarIsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            workbenchSplitView
                .id(workbenchColumnLayout)

            #if FUMINIWA_ENABLE_EXPERIMENTAL_AI
            if aiProofreadingOperation.isPanelPresented {
                Divider()
                AIProofreadingPanelView(
                    operation: aiProofreadingOperation,
                    canCaptureEditorSelection: canCaptureAIEditorSelection
                )
                .frame(minHeight: 224, idealHeight: 300, maxHeight: 440)
            }
            #endif

            if !showsWritingActions {
                WorkbenchStatusBarView()
            }
        }
        .toolbar(id: "novelwriter.workbench.v3") {
            WorkbenchToolbarContent(
                overlayState: overlayState,
                showsWritingActions: showsWritingActions
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
            #if FUMINIWA_ENABLE_EXPERIMENTAL_AI
            if !isWriting {
                aiProofreadingOperation.editorSurfaceDidBecomeUnavailable()
            }
            #endif
        }
        #if FUMINIWA_ENABLE_EXPERIMENTAL_AI
        .onChange(of: appState.documentSessionToken) { _, _ in
                aiProofreadingOperation.documentContextDidChange()
            }
            .onChange(of: appState.selectedChapterID) { _, _ in
                aiProofreadingOperation.documentContextDidChange()
            }
            .onChange(of: appState.selectedEpisodeID) { _, _ in
                aiProofreadingOperation.documentContextDidChange()
            }
            .onChange(of: appState.isDocumentTransitionInProgress) { _, isTransitioning in
                if isTransitioning {
                    aiProofreadingOperation.editorSurfaceDidBecomeUnavailable()
                }
            }
            .onDisappear {
                // snapshot復元などでWorkbench自体が外れる場合は、個別onChangeが
                // 新しいViewの初期値へ吸収されるため、Editor surfaceを明示的に閉じる。
                aiProofreadingOperation.editorSurfaceDidBecomeUnavailable()
            }
        #endif
            .confirmationDialog(
                "このスナップショットに戻しますか？",
                isPresented: snapshotRestoreDialogIsPresented,
                presenting: snapshotMenuPresenter.snapshotPendingRestore
            ) { request in
                Button("戻す", role: .destructive) {
                    Task { await snapshotMenuPresenter.restore(request) }
                }
                Button("キャンセル", role: .cancel) {}
            } message: { request in
                Text("「\(request.snapshot.displayName)」の状態に戻します。いまの内容は先にスナップショットへ退避します。")
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
                Task {
                    guard await appState.selectProjectSectionAfterDeviceSyncDeparture(.references) else { return }
                    attachmentImportSession = appState.documentSessionToken
                    isImportingAttachment = true
                }
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

    @ViewBuilder
    private var workbenchSplitView: some View {
        if usesTwoColumnLayout {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                projectSidebar
            } detail: {
                workbenchDetail
                    .frame(minWidth: 560)
            }
        } else {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                projectSidebar
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
        }
    }

    private var projectSidebar: some View {
        ProjectSidebarView(
            isFocused: $projectSidebarIsFocused,
            onSelect: selectProjectSectionFromSidebar
        )
        .navigationSplitViewColumnWidth(min: 184, ideal: 200, max: 224)
    }

    private func selectProjectSectionFromSidebar(_ section: ProjectSection) {
        Task { @MainActor in
            let previous = appState.workspaceSelection.section
            guard await appState.selectProjectSectionAfterDeviceSyncDeparture(section),
                  WorkbenchColumnLayout.requiresSidebarFocusHandoff(from: previous, to: section) else { return }

            // 2列と3列の切替ではNavigationSplitView自体が再生成される。クリック元の
            // Listが消えた直後、新しいSidebarへだけfirst responderを引き継ぐ。
            let handoffID = UUID()
            sidebarFocusHandoffID = handoffID
            projectSidebarIsFocused = false
            await Task.yield()
            guard sidebarFocusHandoffID == handoffID,
                  appState.workspaceSelection.section == section else { return }
            projectSidebarIsFocused = true
            sidebarFocusHandoffID = nil
        }
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
        case .worldbuilding:
            WorldbuildingOutlineView()
                .navigationTitle(appState.workspaceSelection.section.title)
        case .projectInfo, .settings:
            EmptyView()
        }
    }

    @ViewBuilder
    private var workbenchDetail: some View {
        switch appState.workspaceSelection.section {
        case .structure:
            EditorPaneView()
        case .characters:
            CharacterDetailView { appearance in
                Task {
                    guard await appState.selectProjectSectionAfterDeviceSyncDeparture(.structure) else { return }
                    guard await appState.selectEpisodeAfterDeviceSyncDeparture(
                        appearance.episodeID,
                        in: appearance.chapterID
                    ) else { return }
                    editorSearchSession.requestSelection(range: appearance.range)
                }
            }
        case .plot:
            PlotAndFlagSplitView { chapterID in
                Task {
                    guard await appState.selectProjectSectionAfterDeviceSyncDeparture(.structure) else { return }
                    await appState.selectChapterAfterDeviceSyncDeparture(chapterID)
                }
            }
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
                    .frame(maxWidth: 560, alignment: .leading)
                Divider()
                DeviceSyncSettingsView()
                    .frame(maxWidth: 560, alignment: .leading)
            }
        }
    }

    private var showsWritingActions: Bool {
        appState.workspaceSelection.section == .structure
    }

    #if FUMINIWA_ENABLE_EXPERIMENTAL_AI
    private var canCaptureAIEditorSelection: Bool {
        showsWritingActions &&
            appState.selectedEpisode != nil &&
            appState.permitsLongRunningDocumentOperation
    }
    #endif

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
        case .characters, .references:
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
            ForEach(ProjectSection.allCases) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
        }
        .focused(isFocused)
        .workbenchGlassOutlineStyle()
    }

    private var sectionSelection: Binding<ProjectSection?> {
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
                    WorldNoteRow(note: item.value)
                        .tag(item.value.id)
                        .contextMenu {
                            Button(role: .destructive) {
                                notePendingDeletion = item
                            } label: {
                                Label("削除", systemImage: "trash")
                            }
                        }
                }
                .onMove { offsets, destination in
                    appState.moveWorldNotes(fromOffsets: offsets, toOffset: destination)
                }
            }
            .overlay {
                if appState.document.worldNotes.isEmpty {
                    ContentUnavailableView(
                        "世界観ノートがありません",
                        systemImage: "globe.asia.australia",
                        description: Text("上部の「ノートを追加」または世界観メニューから追加できます。")
                    )
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
            Text("\(ManuscriptMetrics.countCharacters(in: note.content))字")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(displayTitle)、\(ManuscriptMetrics.countCharacters(in: note.content))字")
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
                ContentUnavailableView(
                    "世界観ノートが選択されていません",
                    systemImage: "globe.asia.australia",
                    description: Text("Outlineからノートを選択するか、ノートを追加してください。")
                )
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
        "全体 \(appState.document.manuscriptCharacterCount)字"
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
