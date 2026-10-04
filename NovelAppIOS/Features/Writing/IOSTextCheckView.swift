import NovelTextAnalysis
import NovelWorkspaceUI
import SwiftUI

struct IOSTextCheckView: View {
    let store: IOSDocumentStore
    var onOpenEditor: (() -> Void)?
    @State private var showingIgnored = false
    @State private var showingEditor = false
    @State private var showingReplacement = false
    @State private var scope: String?

    var body: some View {
        let session = store.textCheck
        List {
            Section {
                TextCheckControls(session: session, canCheck: scope == store.workSearchScope && (session.allWork || store.selectedEpisodeID != nil)) {
                    Task { await store.runTextCheck() }
                }
                Button { showingIgnored = true } label: { Text("無視一覧（\(session.ignored.count)件）").frame(minHeight: 44) }
            }
            TextCheckResults(session: session, onJump: jump) { issue in
                guard scope == store.workSearchScope, store.prepareTextCheckReplacement(issue) else { return }
                showingReplacement = true
            }
        }
        .navigationTitle("表記をチェック")
        .onAppear {
            if scope == nil {
                scope = store.workSearchScope
            }; synchronize()
        }
        .onChange(of: store.document.chapters) { _, _ in synchronize() }
        .onChange(of: store.document.characters) { _, _ in synchronize() }
        .onChange(of: store.workSearchScope) { _, _ in showingIgnored = false; synchronize() }
        .onChange(of: store.selectedEpisodeID) {
            _, _ in if !session.allWork {
                session.invalidate()
            }
        }
        .navigationDestination(isPresented: $showingEditor) { IOSEditorPane(store: store, userDefaults: store.userDefaults) }
        .navigationDestination(isPresented: $showingReplacement) { IOSWorkSearchView(store: store, onOpenEditor: onOpenEditor) }
        .sheet(isPresented: $showingIgnored) {
            NavigationStack {
                TextCheckIgnoredList(session: session)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { showingIgnored = false } } }
            }
        }
    }

    private func synchronize() {
        store.synchronizeTextCheck()
        if scope != store.workSearchScope {
            store.textCheck.message = "作品またはアカウントが変わりました。チェック画面を開き直してください。"
        }
    }

    private func jump(_ occurrence: TextCheckOccurrence) {
        guard let scope, scope == store.workSearchScope else { return }
        Task {
            if await store.selectWorkTextMatch(chapterID: occurrence.result.chapterID, episodeID: occurrence.result.id,
                                               source: occurrence.result.source, range: occurrence.match.range, expectedScope: scope) {
                if let onOpenEditor {
                    onOpenEditor()
                } else {
                    showingEditor = true
                }
            } else if scope == store.workSearchScope {
                synchronize(); store.textCheck.message = "本文が変わりました。「チェック」を押してください。"
            }
        }
    }
}
