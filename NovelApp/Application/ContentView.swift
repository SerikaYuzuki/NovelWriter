import EditorKit
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(DocumentPanelPresenter.self) private var documentPanelPresenter
    @Environment(ExportPresenter.self) private var exportPresenter
    @State private var showingLibrary = true
    @State private var showingConflict = false

    var body: some View {
        rootContent
            .sheet(isPresented: $showingConflict) {
                if let conflict = appState.snapshotSyncConflict {
                    ConflictSheet(conflict: conflict) { choice in
                        Task {
                            if await appState.resolveSnapshotConflict(using: choice) {
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
                    get: { appState.operationMessage != nil },
                    set: {
                        if !$0 {
                            appState.dismissOperationMessage()
                        }
                    }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(appState.operationMessage ?? "")
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
            NavigationSplitView {
                LibraryPane(showingLibrary: $showingLibrary)
            } detail: {
                switch appState.startupState {
                case .loading:
                    ProgressView("端末の作品を開いています…")
                case .documentSelection:
                    ContentUnavailableView(
                        "作品を選択してください",
                        systemImage: "books.vertical",
                        description: Text("左の作品一覧から作品を開くか、新しい作品を作成してください。")
                    )
                default:
                    EmptyView()
                }
            }
        }
    }
}

private struct LibraryPane: View {
    @Environment(AppState.self) private var appState
    @Environment(DocumentPanelPresenter.self) private var documentPanelPresenter
    @Binding var showingLibrary: Bool
    @State private var showingHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("作品一覧")
                    .font(.headline)
                Spacer()
                Button("新規", systemImage: "plus") {
                    documentPanelPresenter.presentNewDocument()
                }
                .labelStyle(.iconOnly)
                .help("新しい作品")
                Button("取り込む", systemImage: "square.and.arrow.down") {
                    documentPanelPresenter.presentOpenPanel()
                }
                .labelStyle(.iconOnly)
                .help("作品を取り込む")
                Button("更新", systemImage: "arrow.clockwise") {
                    Task { await appState.refreshSnapshotLibrary() }
                }
                .labelStyle(.iconOnly)
                .help("作品一覧を更新")
                Button("履歴", systemImage: "clock.arrow.circlepath") {
                    Task {
                        await appState.refreshSnapshotHistory()
                        showingHistory = true
                    }
                }
                .labelStyle(.iconOnly)
                .help("スナップショット履歴")
            }
            .padding(.horizontal, 12)
            List {
                Section {
                    ForEach(works) { work in
                        Button {
                            Task { _ = await appState.openLibraryWork(work) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: icon(for: work))
                                    .foregroundStyle(color(for: work))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(work.title)
                                        .lineLimit(1)
                                    Text(label(for: work))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!work.isOpenable)
                        .accessibilityIdentifier("library.work.\(work.id.uuidString)")
                    }
                }
            }
            .listStyle(.sidebar)
            Text(connectionLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .frame(minWidth: 220)
        .opacity(showingLibrary ? 1 : 0)
        .accessibilityHidden(!showingLibrary)
        .sheet(isPresented: $showingHistory) {
            SnapshotHistorySheet {
                showingHistory = false
            }
        }
    }

    private var works: [StartupLibraryWork] {
        if !appState.snapshotSyncLibraryWorks.isEmpty {
            return appState.snapshotSyncLibraryWorks
        }
        if case let .documentSelection(context) = appState.startupState {
            return context.works
        }
        return []
    }

    private var connectionLabel: String {
        switch appState.lastStartupLibraryConnection {
        case .available: "同期済み"
        case .offline: "オフライン・接続時再開"
        case .accountRequired: "サインインすると同期します"
        case .differentAccount: "別のアカウントのため保留中"
        case let .unavailable(message): message
        }
    }

    private func icon(for work: StartupLibraryWork) -> String {
        switch work.remoteProgress {
        case .needsChoice, .readyForSafeAdoption:
            return "exclamationmark.triangle"
        case .pending, .syncing, .retryable:
            return "arrow.triangle.2.circlepath"
        case .offline:
            return "wifi.slash"
        case .failed, .receiptMismatch:
            return "exclamationmark.circle"
        default:
            break
        }
        return switch work.availability {
        case .remoteOnly: "server.rack.and.arrow.down"
        case .cached: "externaldrive"
        case .pending: "arrow.triangle.2.circlepath"
        case .conflict: "exclamationmark.triangle"
        case .parked, .excluded: "lock"
        case .local: "internaldrive"
        }
    }

    private func color(for work: StartupLibraryWork) -> Color {
        switch work.availability {
        case .conflict: .orange
        case .remoteOnly: .blue
        case .parked, .excluded: .secondary
        default: .secondary
        }
    }

    private func label(for work: StartupLibraryWork) -> String {
        switch work.remoteProgress {
        case .pending, .syncing, .retryable:
            return "同期待ち"
        case .offline:
            return "オフライン・接続時再開"
        case .authenticationRequired:
            return "サインインすると同期します"
        case .needsChoice, .readyForSafeAdoption:
            return "競合・確認が必要"
        case .parkedDifferentAccount, .fenceChanged, .quarantined:
            return "別のアカウントのため保留中"
        case .failed, .receiptMismatch:
            return "実エラー"
        case .idle, .noChanges:
            break
        }
        return switch work.availability {
        case .local: "この端末"
        case .cached: "この端末・同期済み"
        case .remoteOnly: "サーバー・未ダウンロード"
        case .pending: "同期待ち"
        case .conflict: "競合・確認が必要"
        case .parked: "別のアカウントのため保留中"
        case .excluded: "表示対象外"
        }
    }
}

private struct SnapshotHistorySheet: View {
    @Environment(AppState.self) private var appState
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("スナップショット履歴")
                .font(.title2.weight(.semibold))
            if appState.snapshotSyncHistory.isEmpty {
                ContentUnavailableView(
                    "履歴はありません",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("この端末の履歴とオンライン履歴を、利用できる範囲で表示します。")
                )
            } else {
                List(appState.snapshotSyncHistory, id: \.occurrenceID) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.reason)
                            Text(entry.createdAt, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(entry.source == .local ? "端末" : "オンライン")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if entry.pinned {
                            Label("保持", systemImage: "pin.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button("復元") {
                            Task {
                                if await appState.restoreSnapshotV2(snapshotID: entry.snapshotID) {
                                    dismiss()
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            Button("閉じる", action: dismiss)
                .buttonStyle(.borderless)
        }
        .padding(24)
        .frame(minWidth: 460, minHeight: 300)
        .accessibilityIdentifier("snapshotSyncV2.historySheet")
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

private struct ConflictSheet: View {
    let conflict: SyncV2ConflictProjection
    let choose: (SyncV2ConflictChoice) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("競合", systemImage: "exclamationmark.triangle")
                .font(.title2.weight(.semibold))
            Text("この端末の版とサーバーの版が分かれています。選択中の入力は先に端末へ保存されます。")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Button("この端末の版を残す") { choose(.useDevice) }
                Button("サーバーの版を採用") { choose(.useServer) }
                Button("両方を残す") { choose(.keepBoth) }
            }
            .buttonStyle(.borderedProminent)
            Button("後で確認", action: cancel)
                .buttonStyle(.borderless)
        }
        .padding(24)
        .frame(width: 420)
        .accessibilityIdentifier("snapshotSyncV2.conflictSheet")
    }
}

#Preview {
    let session = EditorCommandSession()
    let state = AppState(
        dependencies: AppDependencies(editorCommandSession: session),
        initialStartupState: .ready
    )
    return ContentView()
        .environment(state)
        .environment(session)
}
