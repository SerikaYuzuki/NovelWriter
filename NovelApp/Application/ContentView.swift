import EditorKit
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelUI
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(DocumentPanelPresenter.self) private var documentPanelPresenter
    @Environment(ExportPresenter.self) private var exportPresenter
    @State private var showingConflict = false
    @State private var conflictNotice: ConflictResolutionNotice?
    @State private var showingConflictHistory = false

    var body: some View {
        rootContent
            .sheet(isPresented: $showingConflict) {
                if let selection = appState.snapshotSyncV2ConflictSelection,
                   let application = appState.snapshotSyncV2Application {
                    ConflictSheet(application: application, workID: selection.workID,
                                  conflict: selection.conflict, defaults: appState.userDefaults) { choice in
                        await resolve(choice, selection: selection, application: application)
                    } cancel: { showingConflict = false }
                }
            }
            .sheet(isPresented: $showingConflictHistory) { SnapshotHistorySheet { showingConflictHistory = false } }
            .safeAreaInset(edge: .bottom) {
                if let notice = conflictNotice {
                    ConflictResolutionNoticeView(notice: notice) { conflictNotice = nil }
                }
            }
            .onChange(of: appState.currentSnapshotSyncV2WorkID) { _, _ in clearConflictPresentation() }
            .onChange(of: appState.snapshotSyncV2AccountScopeToken) { _, _ in clearConflictPresentation() }
            .alert(
                "作品の操作",
                isPresented: Binding(
                    get: { appState.operationMessage != nil || documentPanelPresenter.alertMessage != nil },
                    set: {
                        if !$0 {
                            appState.dismissOperationMessage()
                            documentPanelPresenter.alertMessage = nil
                        }
                    }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(documentPanelPresenter.alertMessage ?? appState.operationMessage ?? "")
            }
            .onChange(of: appState.snapshotSyncConflict, initial: true) { _, conflict in
                showingConflict = conflict != nil
            }
            .onReceive(NotificationCenter.default.publisher(for: .presentSnapshotSyncConflict)) { _ in
                showingConflict = appState.snapshotSyncConflict != nil
            }
            .alert(
                "作品を開けませんでした",
                isPresented: Binding(
                    get: { appState.externalDocumentOpenErrorMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            appState.externalDocumentOpenErrorMessage = nil
                        }
                    }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(appState.externalDocumentOpenErrorMessage ?? "")
            }
    }

    private func resolve(_ choice: SyncV2ConflictChoice, selection: SnapshotSyncV2ConflictSelection,
                         application: SyncV2Application) async -> Bool {
        guard await appState.resolveSnapshotConflict(using: choice, selection: selection) else { return false }
        showingConflict = false
        let snapshot = choice == .useDevice ? selection.conflict.remoteSnapshotID : selection.conflict.localSnapshotID
        let available = await (try? application.historySnapshotAvailability(workID: selection.workID, snapshotID: snapshot)) == .local
        guard appState.currentSnapshotSyncV2WorkID == selection.workID,
              appState.matchesSnapshotSyncV2AccountScope(selection.accountScope) else { return true }
        let undo: (@MainActor () async -> Bool)? = if available {
            { await appState.undoConflictSelection(selection, choice: choice, snapshotID: snapshot) }
        } else {
            nil
        }
        conflictNotice = ConflictResolutionNotice(
            title: choice == .useDevice ? "この端末の版にしました" : "サーバーの版にしました",
            undo: undo,
            history: { showingConflictHistory = true }
        )
        return true
    }

    private func clearConflictPresentation() {
        showingConflict = false
        showingConflictHistory = false
        conflictNotice = nil
    }

    @ViewBuilder
    private var rootContent: some View {
        switch appState.startupState {
        case .ready:
            // NovelWorkbenchView owns the product NavigationSplitView and its
            // toolbar. Keeping it as the root avoids nesting a second split
            // view around the editor and losing the existing workbench chrome.
            NovelWorkbenchView()
                .disabled(!appState.permitsDocumentInteraction)
        case .recovery:
            RecoveryPane()
        case .loading, .documentSelection:
            LibraryView()
        }
    }
}

private struct RecoveryPane: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ContentUnavailableView(
            "復旧が必要です",
            systemImage: "exclamationmark.triangle",
            description: Text(recoveryMessage)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var recoveryMessage: String {
        if case let .recovery(context) = appState.startupState {
            return context.message
        }
        return "端末の保存領域を確認できませんでした。"
    }
}

#Preview {
    let session = EditorCommandSession()
    guard let defaults = UserDefaults(suiteName: "jp.fuminiwa.preview") else {
        preconditionFailure("Unable to create preview defaults")
    }
    let state = AppState(
        dependencies: AppDependencies(
            userDefaults: defaults,
            editorCommandSession: session
        ),
        initialStartupState: .ready
    )
    return ContentView()
        .environment(state)
        .environment(session)
}
