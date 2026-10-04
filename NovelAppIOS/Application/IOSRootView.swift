import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelUI
import NovelWorkspace
import NovelWorkspaceUI
import SwiftUI
import UniformTypeIdentifiers

struct IOSRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var store: IOSDocumentStore
    @State private var conflictNotice: ConflictResolutionNotice?
    @State private var showingConflictHistory = false
    @State private var workspaceNavigation = IOSWorkspaceNavigationCoordinator()

    var body: some View {
        Group {
            switch store.startupState {
            case .loading:
                ProgressView("作品を読み込んでいます…")
            case .library, .ready:
                IOSWorkbenchView(
                    store: store,
                    navigation: workspaceNavigation
                )
            case let .recovery(message):
                IOSRecoveryView(
                    store: store,
                    message: message,
                    permitsDocumentRecovery: !store.deviceSyncStartupFailedSafely,
                    makeNewDocument: makeNewDocumentFromRecovery
                )
            }
        }
        .task(id: AutomaticSyncObservationID(
            session: store.currentDocumentSessionToken,
            account: store.snapshotSyncV2AccountScope,
            isActive: store.startupState == .ready
        )) {
            if store.startupState == .ready {
                await store.observeSnapshotSyncV2Status()
            }
        }
        .task(id: AutomaticSyncObservationID(
            session: store.currentDocumentSessionToken,
            account: store.snapshotSyncV2AccountScope,
            chapter: store.selectedChapterID, episode: store.selectedEpisodeID,
            isActive: scenePhase == .active && store.startupState == .ready && !store.isDocumentTransitionInProgress
        )) {
            if scenePhase == .active, !store.isDocumentTransitionInProgress {
                await store.runAutomaticSnapshotSyncV2()
            }
        }
        .sheet(isPresented: $store.showsConflictSheet) {
            if let selection = store.snapshotSyncV2DisplayedConflictSelection,
               let application = store.snapshotSyncV2Application {
                ConflictSheet(application: application, workID: selection.workID, conflict: selection.conflict,
                              defaults: store.userDefaults) { choice in
                    await resolve(choice, selection: selection, application: application)
                } cancel: { store.showsConflictSheet = false }
            }
        }
        .sheet(isPresented: $showingConflictHistory) {
            NavigationStack { IOSSnapshotHistoryView(store: store) }
        }
        .onChange(of: store.snapshotSyncConflict, initial: true) { _, conflict in
            store.showsConflictSheet = conflict != nil
        }
        .onChange(of: store.syncV2ActiveWorkID) { _, _ in clearConflictPresentation() }
        .onChange(of: store.snapshotSyncV2AccountScope) { _, _ in clearConflictPresentation() }
        .safeAreaInset(edge: .bottom) {
            if let notice = conflictNotice {
                ConflictResolutionNoticeView(notice: notice) { conflictNotice = nil }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let notice = store.libraryNotice {
                HStack(spacing: Spacing.small) {
                    StatusLabel(notice, systemImage: "checkmark.circle", tone: .success)
                        .font(FuminiwaType.rowSecondary)
                    Spacer()
                    Button("閉じる", systemImage: "xmark") { store.libraryNotice = nil }
                        .labelStyle(.iconOnly)
                }
                .padding(Spacing.medium)
                .background(FuminiwaColor.surface.color)
            }
        }
        .disabled(store.isDocumentTransitionInProgress)
        .overlay {
            if store.showsDocumentTransitionOverlay {
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .ignoresSafeArea()
                    ProgressView("作品を準備しています…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .fileImporter(
            isPresented: $store.isImporterPresented,
            allowedContentTypes: [.fuminiwaNovelPackage],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard !store.deviceSyncStartupFailedSafely else { return }
                guard let url = urls.first else { return }
                Task {
                    guard synchronizeActiveEditorBeforeDocumentChange(),
                          await store.importPackage(from: url) else { return }
                    showCurrentProjectHome()
                }
            case let .failure(error):
                logSyncV2PresentationFailure(error)
                store.operationErrorMessage = remoteOnlyOpenErrorMessage(error)
            }
        }
        .onOpenURL { url in
            guard !store.deviceSyncStartupFailedSafely else { return }
            Task {
                guard synchronizeActiveEditorBeforeDocumentChange(),
                      await store.handleExternalPackageURL(url) else { return }
                showCurrentProjectHome()
            }
        }
        .alert(item: $store.manuscriptCopyNotice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert("作品を操作できませんでした", isPresented: operationErrorIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.operationErrorMessage ?? "不明なエラーです。")
        }
        .sheet(isPresented: exportIsPresented) {
            if let url = store.pendingExportURL {
                IOSShareSheet(items: [url])
                    .ignoresSafeArea()
            }
        }
    }

    private func resolve(_ choice: SyncV2ConflictChoice, selection: IOSSnapshotSyncV2ConflictSelection,
                         application: SyncV2Application) async -> Bool {
        guard await store.resolveSnapshotSyncV2Conflict(using: choice, expectedSelection: selection) else { return false }
        store.showsConflictSheet = false
        let snapshot = choice == .useDevice ? selection.conflict.remoteSnapshotID : selection.conflict.localSnapshotID
        let available = await (try? application.historySnapshotAvailability(workID: selection.workID, snapshotID: snapshot)) == .local
        guard store.syncV2ActiveWorkID == selection.workID,
              store.snapshotSyncV2AccountScope == selection.accountScope else { return true }
        let undo: (@MainActor () async -> Bool)? = if available {
            { await store.undoConflictSelection(selection, choice: choice, snapshotID: snapshot) }
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
        store.showsConflictSheet = false
        showingConflictHistory = false
        conflictNotice = nil
    }

    private func synchronizeActiveEditorBeforeDocumentChange() -> Bool {
        guard let departure = workspaceNavigation.activeEditorDeparture else { return true }
        return IOSWorkspaceEditorSynchronizer.synchronize(
            store: store,
            departure: departure
        )
    }

    private func showCurrentProjectHome() {
        guard let session = store.currentDocumentSessionToken else { return }
        workspaceNavigation.showProjectHome(for: session)
    }

    private func makeNewDocumentFromRecovery() {
        Task {
            guard await store.makeNewDocument() else { return }
            showCurrentProjectHome()
        }
    }

    private var operationErrorIsPresented: Binding<Bool> {
        Binding(
            get: { store.operationErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    store.operationErrorMessage = nil
                }
            }
        )
    }

    private var exportIsPresented: Binding<Bool> {
        Binding(
            get: { store.pendingExportURL != nil },
            set: { isPresented in
                if !isPresented {
                    store.dismissExport()
                }
            }
        )
    }
}

private struct IOSRecoveryView: View {
    let store: IOSDocumentStore
    let message: String
    let permitsDocumentRecovery: Bool
    let makeNewDocument: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("作品を開けませんでした", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            if permitsDocumentRecovery {
                Button("別の作品を取り込む") {
                    store.isImporterPresented = true
                }
                .buttonStyle(.borderedProminent)

                Button("新規作品を作る") {
                    makeNewDocument()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
    }
}

import UIKit

private struct IOSShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context _: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_: UIActivityViewController, context _: Context) {}
}

private struct AutomaticSyncObservationID: Equatable {
    let session: WorkspaceSessionToken?
    let account: WorkspaceAccountScope
    var chapter: ChapterID?
    var episode: EpisodeID?
    let isActive: Bool
}
