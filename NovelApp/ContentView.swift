import EditorKit
import Foundation
import NovelCore
import SwiftUI

/// 画面構成を担当する(docs/DESIGN.md 5.3)。
///
/// ```text
/// NavigationSplitView
/// ├── Sidebar: 章リスト
/// └── Detail: EditorView
/// ```
///
struct ContentView: View {
    @Environment(AppState.self) private var appState

    @State private var chapterPendingDeletion: Chapter?
    @State private var searchQuery = ""
    @State private var searchSelectionRequest: EditorSelectionRequest?
    @State private var lastSearchChapterID: ChapterID?
    @State private var lastSearchQuery = ""
    @State private var lastSearchRange: NSRange?
    @State private var didMissSearch = false
    @State private var isInspectorPresented = true
    @State private var inspectorTab: InspectorTab = .memo
    @State private var operationMessage: OperationMessage?

    var body: some View {
        NavigationSplitView {
            List(selection: selectionBinding) {
                ForEach(appState.document.chapters) { chapter in
                    HStack(spacing: 6) {
                        ChapterTitleField(
                            chapter: chapter,
                            onTitleChange: { title in
                                appState.updateChapterTitle(title, for: chapter.id)
                            },
                            onCommit: {
                                appState.commitChapterTitleEditing()
                            }
                        )

                        if !chapter.memo.isEmpty {
                            Image(systemName: "note.text")
                                .foregroundStyle(.secondary)
                                .help("メモあり")
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            chapterPendingDeletion = chapter
                        } label: {
                            Label("章を削除", systemImage: "trash")
                        }
                        .disabled(appState.document.chapters.count <= 1)
                    }
                    .tag(chapter.id)
                }
                .onMove { offsets, destination in
                    appState.moveChapters(fromOffsets: offsets, toOffset: destination)
                }
            }
            .navigationTitle(appState.document.title)
            .toolbar {
                ToolbarItemGroup {
                    TextField("検索", text: $searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .onSubmit {
                            jumpToSearchResult(direction: .forward)
                        }
                        .onChange(of: searchQuery) { _, newQuery in
                            if lastSearchQuery != newQuery {
                                resetSearchCursor()
                            }
                        }

                    Button {
                        jumpToSearchResult(direction: .backward)
                    } label: {
                        Label("前の検索結果", systemImage: "chevron.up")
                    }
                    .disabled(searchQuery.isEmpty || appState.selectedChapter == nil)

                    Button {
                        jumpToSearchResult(direction: .forward)
                    } label: {
                        Label("次の検索結果", systemImage: "chevron.down")
                    }
                    .disabled(searchQuery.isEmpty || appState.selectedChapter == nil)

                    if didMissSearch {
                        Text("見つかりません")
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        Task { await createSnapshot() }
                    } label: {
                        Label("スナップショットを保存", systemImage: "camera")
                    }

                    Button {
                        isInspectorPresented.toggle()
                    } label: {
                        Label("インスペクタ", systemImage: "sidebar.right")
                    }

                    Button(role: .destructive) {
                        if let chapter = appState.selectedChapter {
                            chapterPendingDeletion = chapter
                        }
                    } label: {
                        Label("章を削除", systemImage: "trash")
                    }
                    .disabled(appState.selectedChapter == nil || appState.document.chapters.count <= 1)

                    Button {
                        appState.addChapter()
                    } label: {
                        Label("章を追加", systemImage: "plus")
                    }
                }
            }
        } detail: {
            if let chapter = appState.selectedChapter {
                VStack(spacing: 0) {
                    EditorView(
                        chapterKey: chapter.id,
                        initialText: chapter.content,
                        selectionRequest: searchSelectionRequest,
                        onTextChange: { newText in
                            appState.updateSelectedChapterContent(newText)
                        }
                    )

                    ManuscriptStatusBar(
                        chapterCharacterCount: ManuscriptMetrics.countCharacters(in: chapter.content),
                        totalCharacterCount: appState.document.manuscriptCharacterCount
                    )
                }
            } else {
                ContentUnavailableView(
                    "章が選択されていません",
                    systemImage: "doc.text",
                    description: Text("左のサイドバーから章を選択するか、章を追加してください。")
                )
            }
        }
        .inspector(isPresented: $isInspectorPresented) {
            InspectorView(
                selectedChapter: appState.selectedChapter,
                memo: selectedChapterMemoBinding,
                selectedTab: $inspectorTab,
                onCharacterSearch: { query in
                    beginSearch(query: query)
                },
                onCharacterAppearanceJump: { appearance in
                    jumpToCharacterAppearance(appearance)
                },
                onPlotChapterJump: { chapterID in
                    appState.selectChapter(chapterID)
                },
                onFlagChapterJump: { chapterID in
                    appState.selectChapter(chapterID)
                }
            )
        }
        .confirmationDialog(
            "章を削除しますか？",
            isPresented: deletionDialogIsPresented,
            presenting: chapterPendingDeletion
        ) { chapter in
            Button("削除", role: .destructive) {
                appState.deleteChapter(id: chapter.id)
                resetSearchCursor()
            }
            Button("キャンセル", role: .cancel) {}
        } message: { chapter in
            Text("「\(chapter.title)」を削除します。")
        }
        .alert(item: $operationMessage) { message in
            Alert(title: Text(message.title), message: Text(message.body), dismissButton: .default(Text("OK")))
        }
        .onChange(of: appState.selection) { _, newSelection in
            if lastSearchChapterID != newSelection {
                resetSearchCursor()
            }
        }
    }

    /// `List(selection:)` に渡すためのバインディング。
    /// 単純な双方向バインディングではなく、選択変更を `AppState.selectChapter(_:)`
    /// に委譲することで、章切り替え時の即時保存(docs/DESIGN.md 6.4)をトリガーする。
    private var selectionBinding: Binding<ChapterID?> {
        Binding(
            get: { appState.selection },
            set: { appState.selectChapter($0) }
        )
    }

    private var deletionDialogIsPresented: Binding<Bool> {
        Binding(
            get: { chapterPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    chapterPendingDeletion = nil
                }
            }
        )
    }

    private var selectedChapterMemoBinding: Binding<String> {
        Binding(
            get: {
                appState.selectedChapter?.memo ?? ""
            },
            set: { memo in
                appState.updateSelectedChapterMemo(memo)
            }
        )
    }

    private func jumpToSearchResult(direction: TextSearchDirection) {
        guard let chapter = appState.selectedChapter, !searchQuery.isEmpty else { return }

        let startLocation: Int = if lastSearchChapterID == chapter.id, lastSearchQuery == searchQuery, let lastSearchRange {
            switch direction {
            case .forward:
                lastSearchRange.location + lastSearchRange.length
            case .backward:
                lastSearchRange.location
            }
        } else {
            switch direction {
            case .forward:
                0
            case .backward:
                (chapter.content as NSString).length
            }
        }

        guard let range = TextSearch.find(
            query: searchQuery,
            in: chapter.content,
            from: startLocation,
            direction: direction
        ) else {
            didMissSearch = true
            return
        }

        didMissSearch = false
        lastSearchChapterID = chapter.id
        lastSearchQuery = searchQuery
        lastSearchRange = range
        searchSelectionRequest = EditorSelectionRequest(range: range)
    }

    private func beginSearch(query: String) {
        searchQuery = query
        resetSearchCursor()
        jumpToSearchResult(direction: .forward)
    }

    private func jumpToCharacterAppearance(_ appearance: CharacterAppearance) {
        searchQuery = appearance.query
        didMissSearch = false
        lastSearchChapterID = appearance.chapterID
        lastSearchQuery = appearance.query
        lastSearchRange = appearance.range
        appState.selectChapter(appearance.chapterID)
        searchSelectionRequest = EditorSelectionRequest(range: appearance.range)
    }

    private func resetSearchCursor() {
        didMissSearch = false
        lastSearchChapterID = nil
        lastSearchQuery = ""
        lastSearchRange = nil
        // 章が切り替わったときに、古いジャンプ要求が残らないようにする。
        // `EditorView` の Coordinator が新しい章向けに作り直された場合、
        // 作り直し前の `searchSelectionRequest` がそのまま残っていると、
        // 新しい章に過去のジャンプが誤って再適用されてしまう。
        searchSelectionRequest = nil
    }

    @MainActor
    private func createSnapshot() async {
        if let url = await appState.createSnapshot() {
            operationMessage = OperationMessage(title: "保存しました", body: url.lastPathComponent)
        } else {
            operationMessage = OperationMessage(title: "保存できませんでした", body: "スナップショット保存に失敗しました。")
        }
    }

    private struct ChapterTitleField: View {
        let chapter: Chapter
        let onTitleChange: (String) -> Void
        let onCommit: () -> Void

        @State private var draftTitle: String
        @FocusState private var isFocused: Bool

        init(chapter: Chapter, onTitleChange: @escaping (String) -> Void, onCommit: @escaping () -> Void) {
            self.chapter = chapter
            self.onTitleChange = onTitleChange
            self.onCommit = onCommit
            _draftTitle = State(initialValue: chapter.title)
        }

        var body: some View {
            TextField("章タイトル", text: $draftTitle)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onChange(of: draftTitle) {
                    onTitleChange(draftTitle)
                }
                .onChange(of: chapter.title) {
                    if !isFocused {
                        draftTitle = chapter.title
                    }
                }
                .onChange(of: isFocused) {
                    if !isFocused {
                        commit()
                    }
                }
                .onSubmit {
                    commit()
                }
        }

        private func commit() {
            let normalizedTitle = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let committedTitle = normalizedTitle.isEmpty ? "無題の章" : normalizedTitle
            if draftTitle != committedTitle {
                draftTitle = committedTitle
                onTitleChange(committedTitle)
            }
            onCommit()
        }
    }

    private struct InspectorView: View {
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
                }
            }
            .frame(minWidth: 260)
        }
    }

    private struct FlagInspectorView: View {
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

    private struct PlotInspectorView: View {
        @Environment(AppState.self) private var appState

        let onChapterJump: (ChapterID) -> Void

        @State private var plotCardPendingDeletion: PlotCard?

        var body: some View {
            VStack(spacing: 0) {
                List(selection: plotCardSelectionBinding) {
                    ForEach(appState.document.plotCards) { card in
                        PlotCardRow(card: card, chapterTitle: chapterTitle(for: card.chapterID))
                            .tag(card.id)
                            .contextMenu {
                                Button(role: .destructive) {
                                    plotCardPendingDeletion = card
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                            }
                    }
                    .onMove { offsets, destination in
                        appState.movePlotCards(fromOffsets: offsets, toOffset: destination)
                    }
                }
                .frame(minHeight: 130)

                Divider()

                HStack {
                    Button {
                        appState.addPlotCard()
                    } label: {
                        Label("追加", systemImage: "plus")
                    }

                    Button(role: .destructive) {
                        if let card = appState.selectedPlotCard {
                            plotCardPendingDeletion = card
                        }
                    } label: {
                        Label("削除", systemImage: "trash")
                    }
                    .disabled(appState.selectedPlotCard == nil)

                    Spacer()
                }
                .padding(10)

                Divider()

                if appState.selectedPlotCard == nil {
                    ContentUnavailableView("プロットカードが選択されていません", systemImage: "rectangle.stack")
                        .frame(maxHeight: .infinity)
                } else {
                    PlotCardEditor(
                        title: selectedPlotCardTitleBinding,
                        memo: selectedPlotCardMemoBinding,
                        chapterID: selectedPlotCardChapterBinding,
                        chapters: appState.document.chapters,
                        onJump: {
                            if let chapterID = appState.selectedPlotCard?.chapterID {
                                onChapterJump(chapterID)
                            }
                        },
                        onCommit: {
                            appState.commitPlotCardEditing()
                        }
                    )
                }
            }
            .confirmationDialog(
                "プロットカードを削除しますか？",
                isPresented: plotCardDeletionDialogIsPresented,
                presenting: plotCardPendingDeletion
            ) { card in
                Button("削除", role: .destructive) {
                    appState.deletePlotCard(id: card.id)
                }
                Button("キャンセル", role: .cancel) {}
            } message: { card in
                Text("「\(card.title)」を削除します。")
            }
        }

        private var plotCardSelectionBinding: Binding<PlotCardID?> {
            Binding(
                get: { appState.selectedPlotCardID },
                set: { appState.selectPlotCard($0) }
            )
        }

        private var plotCardDeletionDialogIsPresented: Binding<Bool> {
            Binding(
                get: { plotCardPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        plotCardPendingDeletion = nil
                    }
                }
            )
        }

        private var selectedPlotCardTitleBinding: Binding<String> {
            Binding(
                get: { appState.selectedPlotCard?.title ?? "" },
                set: { appState.updateSelectedPlotCard(title: $0) }
            )
        }

        private var selectedPlotCardMemoBinding: Binding<String> {
            Binding(
                get: { appState.selectedPlotCard?.memo ?? "" },
                set: { appState.updateSelectedPlotCard(memo: $0) }
            )
        }

        private var selectedPlotCardChapterBinding: Binding<ChapterID?> {
            Binding(
                get: { appState.selectedPlotCard?.chapterID },
                set: { appState.updateSelectedPlotCardChapter($0) }
            )
        }

        private func chapterTitle(for chapterID: ChapterID?) -> String? {
            guard let chapterID else { return nil }
            return appState.document.chapters.first { $0.id == chapterID }?.title
        }
    }

    private struct CharacterInspectorView: View {
        @Environment(AppState.self) private var appState

        let onSearchQuery: (String) -> Void
        let onAppearanceJump: (CharacterAppearance) -> Void

        @State private var characterPendingDeletion: NovelCore.Character?

        var body: some View {
            VStack(spacing: 0) {
                List(selection: characterSelectionBinding) {
                    ForEach(appState.document.characters) { character in
                        CharacterRow(character: character)
                            .tag(character.id)
                            .contextMenu {
                                Button(role: .destructive) {
                                    characterPendingDeletion = character
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                            }
                    }
                    .onMove { offsets, destination in
                        appState.moveCharacters(fromOffsets: offsets, toOffset: destination)
                    }
                }
                .frame(minHeight: 120)

                Divider()

                HStack {
                    Button {
                        appState.addCharacter()
                    } label: {
                        Label("追加", systemImage: "plus")
                    }

                    Button(role: .destructive) {
                        if let character = appState.selectedCharacter {
                            characterPendingDeletion = character
                        }
                    } label: {
                        Label("削除", systemImage: "trash")
                    }
                    .disabled(appState.selectedCharacter == nil)

                    Spacer()
                }
                .padding(10)

                Divider()

                if appState.selectedCharacter == nil {
                    ContentUnavailableView("キャラクターが選択されていません", systemImage: "person")
                        .frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        CharacterEditor(
                            name: selectedCharacterNameBinding,
                            kana: selectedCharacterKanaBinding,
                            memo: selectedCharacterMemoBinding,
                            colorHex: selectedCharacterColorBinding,
                            onSearchName: {
                                if let query = selectedCharacterSearchQuery {
                                    onSearchQuery(query)
                                }
                            },
                            onCommit: {
                                appState.commitCharacterEditing()
                            }
                        )

                        CharacterAppearancesView(
                            appearances: selectedCharacterAppearances,
                            onJump: onAppearanceJump
                        )
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                    }
                }
            }
            .confirmationDialog(
                "キャラクターを削除しますか？",
                isPresented: characterDeletionDialogIsPresented,
                presenting: characterPendingDeletion
            ) { character in
                Button("削除", role: .destructive) {
                    appState.deleteCharacter(id: character.id)
                }
                Button("キャンセル", role: .cancel) {}
            } message: { character in
                Text("「\(character.name)」を削除します。")
            }
        }

        private var characterSelectionBinding: Binding<CharacterID?> {
            Binding(
                get: { appState.selectedCharacterID },
                set: { appState.selectCharacter($0) }
            )
        }

        private var characterDeletionDialogIsPresented: Binding<Bool> {
            Binding(
                get: { characterPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        characterPendingDeletion = nil
                    }
                }
            )
        }

        private var selectedCharacterNameBinding: Binding<String> {
            Binding(
                get: { appState.selectedCharacter?.name ?? "" },
                set: { appState.updateSelectedCharacter(name: $0) }
            )
        }

        private var selectedCharacterKanaBinding: Binding<String> {
            Binding(
                get: { appState.selectedCharacter?.kana ?? "" },
                set: { appState.updateSelectedCharacter(kana: $0) }
            )
        }

        private var selectedCharacterMemoBinding: Binding<String> {
            Binding(
                get: { appState.selectedCharacter?.memo ?? "" },
                set: { appState.updateSelectedCharacter(memo: $0) }
            )
        }

        private var selectedCharacterColorBinding: Binding<String?> {
            Binding(
                get: { appState.selectedCharacter?.colorHex },
                set: { colorHex in
                    appState.updateSelectedCharacterColor(colorHex)
                }
            )
        }

        private var selectedCharacterSearchQuery: String? {
            guard let character = appState.selectedCharacter else { return nil }
            let name = NovelDocument.normalizedCharacterName(character.name)
            return name.isEmpty ? nil : name
        }

        private var selectedCharacterAppearances: [CharacterAppearance] {
            guard let character = appState.selectedCharacter else { return [] }
            let queries = appearanceQueries(for: character)
            guard !queries.isEmpty else { return [] }

            return appState.document.chapters.compactMap { chapter in
                for query in queries {
                    if let range = TextSearch.find(query: query, in: chapter.content, from: 0, wraps: false) {
                        return CharacterAppearance(
                            chapterID: chapter.id,
                            chapterTitle: chapter.title,
                            query: query,
                            range: range
                        )
                    }
                }
                return nil
            }
        }

        private func appearanceQueries(for character: NovelCore.Character) -> [String] {
            var seen: Set<String> = []
            let candidates = [
                NovelDocument.normalizedCharacterName(character.name),
                character.kana.trimmingCharacters(in: .whitespacesAndNewlines)
            ]

            return candidates.compactMap { candidate in
                guard !candidate.isEmpty, !seen.contains(candidate) else { return nil }
                seen.insert(candidate)
                return candidate
            }
        }
    }

    private struct CharacterRow: View {
        let character: NovelCore.Character

        var body: some View {
            HStack(spacing: 8) {
                CharacterColorSwatch(colorHex: character.colorHex)

                VStack(alignment: .leading, spacing: 2) {
                    Text(NovelDocument.normalizedCharacterName(character.name))
                        .lineLimit(1)
                    if !character.kana.isEmpty {
                        Text(character.kana)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private struct CharacterEditor: View {
        @Binding var name: String
        @Binding var kana: String
        @Binding var memo: String
        @Binding var colorHex: String?

        let onSearchName: () -> Void
        let onCommit: () -> Void

        private let colorChoices = ["#C44536", "#2E7D32", "#1565C0", "#6A4C93", "#B7791F"]

        var body: some View {
            Form {
                TextField("名前", text: $name)
                    .onSubmit(onCommit)

                TextField("ふりがな", text: $kana)
                    .onSubmit(onCommit)

                Picker("カラー", selection: $colorHex) {
                    Text("なし")
                        .tag(nil as String?)
                    ForEach(colorChoices, id: \.self) { colorHex in
                        HStack {
                            CharacterColorSwatch(colorHex: colorHex)
                            Text(colorHex)
                        }
                        .tag(colorHex as String?)
                    }
                }
                .pickerStyle(.menu)

                Button {
                    onSearchName()
                } label: {
                    Label("この名前で本文検索", systemImage: "magnifyingglass")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("メモ")
                        .foregroundStyle(.secondary)
                    TextEditor(text: $memo)
                        .frame(minHeight: 140)
                }
            }
            .formStyle(.grouped)
            .padding(10)
            .onDisappear(perform: onCommit)
        }
    }

    private struct CharacterAppearancesView: View {
        let appearances: [CharacterAppearance]
        let onJump: (CharacterAppearance) -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("登場章")
                    .font(.headline)

                if appearances.isEmpty {
                    Text("本文中に見つかりません")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appearances) { appearance in
                        Button {
                            onJump(appearance)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(appearance.chapterTitle)
                                        .lineLimit(1)
                                    Text("「\(appearance.query)」")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrowshape.turn.up.right")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private struct PlotCardRow: View {
        let card: PlotCard
        let chapterTitle: String?

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(NovelDocument.normalizedPlotCardTitle(card.title))
                    .lineLimit(1)
                if let chapterTitle {
                    Text(chapterTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private struct PlotCardEditor: View {
        @Binding var title: String
        @Binding var memo: String
        @Binding var chapterID: ChapterID?

        let chapters: [Chapter]
        let onJump: () -> Void
        let onCommit: () -> Void

        var body: some View {
            Form {
                TextField("タイトル", text: $title)
                    .onSubmit(onCommit)

                Picker("章", selection: $chapterID) {
                    Text("未設定")
                        .tag(nil as ChapterID?)
                    ForEach(chapters) { chapter in
                        Text(chapter.title)
                            .tag(chapter.id as ChapterID?)
                    }
                }

                Button {
                    onJump()
                } label: {
                    Label("紐付き章へジャンプ", systemImage: "arrowshape.turn.up.right")
                }
                .disabled(chapterID == nil)

                VStack(alignment: .leading, spacing: 6) {
                    Text("メモ")
                        .foregroundStyle(.secondary)
                    TextEditor(text: $memo)
                        .frame(minHeight: 180)
                }
            }
            .formStyle(.grouped)
            .padding(10)
            .onDisappear(perform: onCommit)
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

    private struct CharacterColorSwatch: View {
        let colorHex: String?

        var body: some View {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .overlay {
                    Circle()
                        .stroke(.secondary.opacity(0.35), lineWidth: 1)
                }
        }

        private var color: Color {
            guard let colorHex, let color = Color(hex: colorHex) else {
                return .clear
            }
            return color
        }
    }

    private struct ManuscriptStatusBar: View {
        let chapterCharacterCount: Int
        let totalCharacterCount: Int

        var body: some View {
            HStack(spacing: 16) {
                Text("章 \(chapterCharacterCount)字 / \(ManuscriptMetrics.manuscriptPages400(for: chapterCharacterCount))枚")
                Spacer()
                Text("全体 \(totalCharacterCount)字 / \(ManuscriptMetrics.manuscriptPages400(for: totalCharacterCount))枚")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    private enum InspectorTab: Hashable {
        case memo
        case characters
        case plot
        case flags
    }

    private struct OperationMessage: Identifiable {
        let id = UUID()
        let title: String
        let body: String
    }

    private struct CharacterAppearance: Identifiable {
        let chapterID: ChapterID
        let chapterTitle: String
        let query: String
        let range: NSRange

        var id: String {
            "\(chapterID.rawValue.uuidString)-\(query)-\(range.location)"
        }
    }
}

private extension Color {
    init?(hex: String) {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard trimmed.count == 6, let value = Int(trimmed, radix: 16) else { return nil }

        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0
        self.init(red: red, green: green, blue: blue)
    }
}

#Preview {
    ContentView()
        .environment(AppState(dependencies: AppDependencies()))
}
