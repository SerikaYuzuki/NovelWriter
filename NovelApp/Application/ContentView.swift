import EditorKit
import NovelLocalStore
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(DocumentPanelPresenter.self) private var documentPanelPresenter
    @Environment(ExportPresenter.self) private var exportPresenter
    @State private var isStartupWorkRecoveryPresented = false
    @State private var isSnapshotConflictPresented = false

    var body: some View {
        Group {
            switch appState.startupState {
            case .loading:
                StartupLoadingView()
            case let .documentSelection(context):
                StartupDocumentSelectionView(context: context)
            case .ready:
                NovelWorkbenchView()
                    .disabled(!appState.permitsDocumentInteraction)
            case let .recovery(context):
                StartupRecoveryView(context: context)
            }
        }
        .alert(
            "操作を完了できませんでした",
            isPresented: Binding(
                get: { documentPanelPresenter.alertMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        documentPanelPresenter.alertMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(documentPanelPresenter.alertMessage ?? "")
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
        .alert(
            "作品の操作",
            isPresented: Binding(
                get: { appState.cloudLibraryActionMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        appState.dismissCloudLibraryActionMessage()
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.cloudLibraryActionMessage ?? "")
        }
        .overlay {
            if appState.startupState.isReady,
               appState.usesWholeWorkSyncRuntime,
               !appState.usesNoteSyncRuntime,
               appState.deviceSyncLocalRecoveryPending {
                StartupWorkSyncGateView(
                    requiresReview: appState.workSyncLocalRecoveryReview != nil,
                    review: { isStartupWorkRecoveryPresented = true }
                )
            }
        }
        .sheet(isPresented: $isStartupWorkRecoveryPresented) {
            if let review = appState.workSyncLocalRecoveryReview {
                let session = appState.documentSessionToken
                WorkConflictResolutionView(
                    presentation: WorkConflictPresentationAdapter.make(localRecovery: review),
                    isApplying: appState.isApplyingWorkSyncConflict,
                    choose: { choice in
                        Task {
                            await appState.resolveWorkSyncLocalRecovery(
                                using: choice,
                                expectedReview: review,
                                expectedSession: session
                            )
                        }
                    },
                    reviewLater: { isStartupWorkRecoveryPresented = false }
                )
                .id("startup-local-recovery:\(review.materializedRevision.revisionID)")
            }
        }
        .sheet(isPresented: $isSnapshotConflictPresented) {
            if let conflict = appState.snapshotSyncConflict {
                SnapshotSyncConflictResolutionView(
                    conflict: conflict,
                    isApplying: appState.isSnapshotSyncInFlight,
                    choose: { choice in
                        Task {
                            if await appState.resolveSnapshotConflict(using: choice) {
                                isSnapshotConflictPresented = false
                            }
                        }
                    },
                    dismiss: { isSnapshotConflictPresented = false }
                )
                .id("snapshot-conflict:\(conflict.conflictID.uuidString)")
            }
        }
        .onChange(of: appState.workSyncLocalRecoveryReview, initial: true) { _, review in
            isStartupWorkRecoveryPresented = review != nil
        }
        .onChange(of: appState.snapshotSyncConflict, initial: true) { _, conflict in
            isSnapshotConflictPresented = conflict != nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .presentSnapshotSyncConflict)) { _ in
            guard appState.snapshotSyncConflict != nil else { return }
            isSnapshotConflictPresented = true
        }
        .overlay(alignment: .bottomTrailing) {
            VStack(alignment: .trailing, spacing: 8) {
                if appState.startupState.isReady,
                   let notice = appState.aiClipboardPromptCopyNotice {
                    AIClipboardPromptCopyNoticeView(
                        notice: notice,
                        onDismiss: appState.dismissAIClipboardPromptCopyNotice
                    )
                }

                if appState.startupState.isReady, exportPresenter.state != .idle {
                    ExportStatusView(presenter: exportPresenter)
                }
            }
            .padding(16)
        }
    }
}

private struct StartupWorkSyncGateView: View {
    let requiresReview: Bool
    let review: () -> Void

    var body: some View {
        Group {
            if requiresReview {
                ContentUnavailableView {
                    Label("変更の確認が必要です", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("端末に残っている作品の版を確認してから、執筆を再開できます。")
                } actions: {
                    Button("変更を確認", action: review)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("startup.workSyncRecovery.review")
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("作品の保存状態を確認中")
                    Text("作品の保存状態を確認しています…")
                        .font(.headline)
                    Text("端末に保存された内容を確認してから、執筆画面を開きます。")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .accessibilityIdentifier("startup.workSyncRecovery")
    }
}

extension Notification.Name {
    static let toggleWritingInspector = Notification.Name("dev.serikayuzuki.fuminiwa.toggleWritingInspector")
    static let presentChapterTitleEditor = Notification.Name("dev.serikayuzuki.fuminiwa.presentChapterTitleEditor")
    static let presentChapterMemo = Notification.Name("dev.serikayuzuki.fuminiwa.presentChapterMemo")
    static let presentAttachmentImporter = Notification.Name("dev.serikayuzuki.fuminiwa.presentAttachmentImporter")
    static let presentSnapshotSyncConflict = Notification.Name("dev.serikayuzuki.fuminiwa.presentSnapshotSyncConflict")
}

#Preview {
    let editorCommandSession = EditorCommandSession()
    let appState = AppState(
        dependencies: AppDependencies(editorCommandSession: editorCommandSession),
        initialStartupState: .ready
    )
    return ContentView()
        .environment(appState)
        .environment(EditorSettings())
        .environment(DocumentPanelPresenter(appState: appState))
        .environment(SnapshotMenuPresenter(appState: appState))
        .environment(ExportPresenter(appState: appState))
        .environment(EditorSearchSession())
        .environment(editorCommandSession)
}
