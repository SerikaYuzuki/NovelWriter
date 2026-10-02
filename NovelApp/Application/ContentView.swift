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

    var body: some View {
        rootContent
            .sheet(isPresented: $showingConflict) {
                if let selection = appState.snapshotSyncV2ConflictSelection {
                    ConflictSheet { choice in
                        Task {
                            if await appState.resolveSnapshotConflict(using: choice, selection: selection) {
                                showingConflict = false
                            }
                        }
                    } cancel: {
                        showingConflict = false
                    }
                }
            }
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

struct ConflictSheet: View {
    let choose: (SyncV2ConflictChoice) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("競合", systemImage: "exclamationmark.triangle")
                .font(.title2.weight(.semibold))
            Text("この端末の版とサーバーの版が分かれています。選択中の入力は先に端末へ保存されます。")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                choiceRow("この端末の版を使う", symbol: "internaldrive", description: "この端末の変更をサーバーへ送ります。", choice: .useDevice)
                choiceRow("サーバーの版を使う", symbol: "arrow.down.circle", description: "サーバーで確認済みの版を、この端末へ適用します。", choice: .useServer)
                choiceRow("両方を残す", symbol: "doc.on.doc", description: "元の作品を保ち、もう一つの作品として残します。", choice: .keepBoth)
            }
            .buttonStyle(.bordered)
            Button("後で確認", action: cancel)
                .buttonStyle(.borderless)
        }
        .padding(24)
        .frame(width: 420)
        .background(FuminiwaColor.paper.color)
        .accessibilityIdentifier("snapshotSyncV2.conflictSheet")
    }

    private func choiceRow(_ title: String, symbol: String, description: String, choice: SyncV2ConflictChoice) -> some View {
        Button { choose(choice) } label: {
            HStack(alignment: .top, spacing: Spacing.medium) {
                Image(systemName: symbol).symbolRenderingMode(.hierarchical)
                VStack(alignment: .leading, spacing: Spacing.extraSmall) {
                    Text(title).font(.headline)
                    Text(description).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(Spacing.small)
        }
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
