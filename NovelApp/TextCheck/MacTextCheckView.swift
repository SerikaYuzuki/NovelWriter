import NovelTextAnalysis
import NovelUI
import NovelWorkspaceUI
import SwiftUI

struct MacTextCheckView: View {
    @Environment(AppState.self) private var state
    @Environment(EditorSearchSession.self) private var editorSearch
    @State private var showingIgnored = false

    var body: some View {
        let session = state.textCheck
        VStack(spacing: Spacing.small) {
            HStack {
                Text("表記・記号チェック").font(.headline)
                Spacer()
                Button { close() } label: { Image(systemName: "xmark") }.accessibilityLabel("チェックを閉じる")
            }
            .padding(.horizontal, Spacing.medium)
            List {
                Section {
                    TextCheckControls(session: session, canCheck: state.permitsDocumentInteraction && (session.allWork || state.selectedEpisodeID != nil)) {
                        Task { await state.runTextCheck() }
                    }
                    Button("無視一覧（\(session.ignored.count)件）") { showingIgnored = true }
                }
                TextCheckResults(session: session, onJump: jump) { issue in
                    Task { _ = await state.presentTextCheckReplacement(issue) }
                }
            }
            .workbenchOutlineListStyle()
        }
        .padding(.top, Spacing.medium)
        .workbenchGlassChromeStyle()
        .onAppear { state.synchronizeTextCheck() }
        .onChange(of: state.document.chapters) { _, _ in state.synchronizeTextCheck() }
        .onChange(of: state.document.characters) { _, _ in state.synchronizeTextCheck() }
        .onChange(of: state.workSearchScope) { _, _ in showingIgnored = false; state.synchronizeTextCheck() }
        .onChange(of: state.selectedEpisodeID) {
            _, _ in if !session.allWork {
                session.invalidate()
            }
        }
        .onExitCommand { close() }
        .sheet(isPresented: $showingIgnored) {
            VStack {
                Text("無視一覧（この端末）").font(.headline)
                TextCheckIgnoredList(session: session)
                Button("閉じる") { showingIgnored = false }
            }
            .padding(Spacing.medium)
            .frame(minWidth: 320, minHeight: 360)
        }
    }

    private func close() {
        state.textCheck.invalidate(); state.textCheck.isPresented = false
    }

    private func jump(_ occurrence: TextCheckOccurrence) {
        let scope = state.textCheck.scope
        Task {
            guard scope == state.workSearchScope,
                  await state.selectWorkTextMatch(occurrence.result, match: occurrence.match, expectedScope: scope, editorSearch: editorSearch) else {
                state.synchronizeTextCheck(); state.textCheck.message = "本文が変わりました。「チェック」を押してください。"; return
            }
        }
    }
}
