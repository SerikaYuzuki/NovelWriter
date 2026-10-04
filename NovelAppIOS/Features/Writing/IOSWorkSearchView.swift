import NovelTextAnalysis
import NovelUI
import NovelWorkspaceUI
import SwiftUI

struct IOSWorkSearchView: View {
    let store: IOSDocumentStore
    var initialQuery: String?
    var onOpenEditor: (() -> Void)?
    @State private var confirmingReplacement = false
    @State private var showingEditor = false
    @State private var scope: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        @Bindable var search = store.workSearch
        List {
            Section {
                if search.isSearching {
                    ProgressView("検索中")
                }
                Text("\(search.total)件").monospacedDigit()
            }
            if search.isStale, !search.isSearching {
                Section {
                    Text("本文が変わりました。結果を更新してください。").foregroundStyle(.secondary)
                    Button("再検索") { refresh() }
                }
            }
            WorkSearchResults(search: search, onJump: jump)
                .disabled(search.isReplacing)
            if let message = search.message {
                Section { Text(message).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("作品全体を検索")
        .searchable(text: $search.query, prompt: "本文を検索")
        .safeAreaInset(edge: .bottom) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: Spacing.small) { replacementActions }
                } else {
                    HStack(spacing: Spacing.medium) { replacementActions }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(Spacing.small)
            .background(.bar)
        }
        .onAppear {
            if scope == nil {
                scope = store.workSearchScope
                if let initialQuery {
                    search.query = initialQuery
                }
            }
            guard scope == store.workSearchScope else { search.invalidate(); return }
            search.setVisible(true, document: store.document, scope: store.workSearchScope)
        }
        .onDisappear { search.setVisible(false, document: store.document, scope: store.workSearchScope) }
        .onChange(of: search.query) { _, _ in refresh() }
        .onChange(of: store.localEditGeneration) { _, _ in confirmingReplacement = false; search.markStale() }
        .onChange(of: store.workSearchScope) { _, _ in confirmingReplacement = false; refresh() }
        .navigationDestination(isPresented: $showingEditor) {
            IOSEditorPane(store: store, userDefaults: store.userDefaults)
        }
        .sheet(isPresented: $confirmingReplacement) {
            NavigationStack {
                Form {
                    TextField("置換後の文字列", text: $search.replacement)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("workSearch.replacement")
                    Text("\(search.includedCount)件を置換します。置換前の本文を履歴に保存します。検索後に本文が変わっていた場合は置換を中止します。")
                }
                .navigationTitle("本文を置換")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { confirmingReplacement = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("置換", role: .destructive) {
                            guard scope == store.workSearchScope else { confirmingReplacement = false; return }
                            let host = store.workReplacementHost
                            confirmingReplacement = false
                            Task { _ = await search.replace(using: host) }
                        }
                        .disabled(search.includedCount == 0 || search.isSearching || search.isReplacing || search.isStale)
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder
    private var replacementActions: some View {
        let search = store.workSearch
        Button { confirmingReplacement = true } label: {
            Text("\(search.includedCount)件を置換…").frame(minHeight: 44)
        }
        .disabled(search.includedCount == 0 || search.isSearching || search.isReplacing || search.isStale)
        if search.canUndo {
            Button { Task { _ = await search.undo(using: store.workReplacementHost) } } label: {
                Text("元に戻す").frame(minHeight: 44)
            }
            .disabled(search.isReplacing)
        }
    }

    private func refresh() {
        guard scope == store.workSearchScope else { store.workSearch.invalidate(); return }
        store.workSearch.refresh(document: store.document, scope: store.workSearchScope)
    }

    private func jump(_ result: EpisodeTextMatches, _ match: WorkTextMatch) {
        guard let scope, scope == store.workSearchScope else { return }
        Task {
            if await store.selectWorkTextMatch(chapterID: result.chapterID, episodeID: result.id,
                                               source: result.source, range: match.range, expectedScope: scope) {
                if let onOpenEditor {
                    onOpenEditor()
                } else {
                    showingEditor = true
                }
            } else if scope == store.workSearchScope {
                store.workSearch.message = "本文が変わりました。もう一度検索してください。"
            }
        }
    }
}
