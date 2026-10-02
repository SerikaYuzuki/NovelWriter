import NovelTextAnalysis
import NovelUI
import SwiftUI

struct MacWorkSearchView: View {
    @Environment(AppState.self) private var appState
    @Environment(EditorSearchSession.self) private var editorSearch
    @State private var confirmingReplacement = false
    @FocusState private var queryFocused: Bool

    var body: some View {
        @Bindable var search = appState.workSearch
        VStack(spacing: Spacing.small) {
            HStack {
                Text("作品全体を検索").font(.headline)
                Spacer()
                Button { search.isPresented = false } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("検索を閉じる")
            }
            .padding(.horizontal, Spacing.medium)
            TextField("本文を検索", text: $search.query)
                .textFieldStyle(.roundedBorder)
                .focused($queryFocused)
                .accessibilityIdentifier("workSearch.query")
                .padding(.horizontal, Spacing.medium)
            TextField("置換後の文字列", text: $search.replacement)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("workSearch.replacement")
                .padding(.horizontal, Spacing.medium)
            HStack {
                if search.isSearching {
                    ProgressView().controlSize(.small)
                }
                Text("\(search.total)件").font(.caption).monospacedDigit()
                Spacer()
                Button("\(search.includedCount)件を置換…") { confirmingReplacement = true }
                    .disabled(search.includedCount == 0 || search.isSearching || search.isReplacing)
            }
            .padding(.horizontal, Spacing.medium)
            List {
                WorkSearchResults(search: search, onJump: jump)
                    .disabled(search.isReplacing)
            }
            .workbenchOutlineListStyle()
            if let message = search.message {
                Text(message).font(.caption).foregroundStyle(.secondary).padding(.horizontal, Spacing.medium)
            }
            if search.canUndo {
                Button("元に戻す") { Task { _ = await search.undo(using: appState.workReplacementHost) } }
                    .disabled(search.isReplacing)
                    .padding(.bottom, Spacing.small)
            }
        }
        .padding(.top, Spacing.medium)
        .workbenchGlassChromeStyle()
        .onAppear { refresh(); queryFocused = true }
        .onChange(of: search.query) { _, _ in confirmingReplacement = false; refresh() }
        .onChange(of: appState.document.chapters) { _, _ in confirmingReplacement = false; refresh() }
        .onChange(of: appState.workSearchScope) { _, _ in confirmingReplacement = false; refresh() }
        .onExitCommand { search.isPresented = false }
        .confirmationDialog("\(search.includedCount)件を置換しますか？", isPresented: $confirmingReplacement) {
            Button("置換", role: .destructive) {
                let host = appState.workReplacementHost
                Task { _ = await search.replace(using: host) }
            }
            Button("キャンセル", role: .cancel) {}
        } message: { Text("置換前の本文を履歴に保存します。検索後に本文が変わっていた場合は置換を中止します。") }
    }

    private func refresh() {
        appState.workSearch.refresh(document: appState.document, scope: appState.workSearchScope)
    }

    private func jump(_ result: EpisodeTextMatches, _ match: WorkTextMatch) {
        let scope = appState.workSearchScope
        Task {
            guard appState.workSearch.scope == scope,
                  await appState.selectWorkTextMatch(result, match: match, expectedScope: scope, editorSearch: editorSearch) else {
                appState.workSearch.message = "本文が変わりました。もう一度検索してください。"; return
            }
        }
    }
}
