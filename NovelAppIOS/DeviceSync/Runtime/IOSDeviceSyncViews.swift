import NovelSync
import SwiftUI

struct IOSDeviceSyncStatusControl: View {
    let saveState: IOSSaveState
    let state: IOSDeviceSyncUIState
    let transferState: IOSDeviceSyncTransferState
    let localDurabilityState: IOSDeviceSyncLocalDurabilityState
    let hasLocalRecoveryReview: Bool
    let isLocalRecoveryReviewReady: Bool
    var usesWholeWorkSync = false
    let reviewChanges: () -> Void

    @State private var showsDetails = false

    var body: some View {
        Button {
            if resolvedStatus == .needsReview {
                reviewChanges()
            } else {
                showsDetails.toggle()
            }
        } label: {
            if resolvedStatus.showsProgress {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: resolvedStatus.systemImage)
            }
        }
        .foregroundStyle(resolvedStatus.isWarning ? .orange : .secondary)
        .accessibilityLabel(resolvedStatus.accessibilityLabel)
        .accessibilityHint(resolvedStatus == .needsReview ? "変更内容を確認します" : "保存と同期の詳細を表示します")
        .accessibilityIdentifier("ios.deviceSync.status")
        .popover(isPresented: $showsDetails) {
            VStack(alignment: .leading, spacing: 8) {
                Label(resolvedStatus.accessibilityLabel, systemImage: resolvedStatus.systemImage)
                    .font(.headline)
                Text(usesWholeWorkSync ? wholeWorkDetail : resolvedStatus.detail)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .presentationCompactAdaptation(.popover)
        }
        .onChange(of: resolvedStatus) { _, current in
            if current == .needsReview {
                showsDetails = false
            }
        }
    }

    var resolvedStatus: IOSDeviceSyncEditorStatusKind {
        IOSDeviceSyncEditorStatusKind.resolveForCurrentWork(
            saveState: saveState,
            syncState: state,
            transferState: transferState,
            localDurability: localDurabilityState,
            hasLocalRecoveryReview: hasLocalRecoveryReview,
            isLocalRecoveryReviewReady: isLocalRecoveryReviewReady,
            usesWholeWorkSync: usesWholeWorkSync
        )
    }

    private var wholeWorkDetail: String {
        switch resolvedStatus {
        case .savingLocally:
            "作品をこの端末へ保存しています。入力はそのまま続けられます。"
        case .savedLocally:
            "作品はこの端末に保存されています。iCloudへ送るには「iCloudと同期」を使います。"
        case .syncing:
            "作品はこの端末に保存されています。iCloudへの反映を続けています。"
        case .synced:
            "作品はこの端末とiCloudの両方に保存されています。"
        case .offline:
            "作品はこの端末に保存されています。接続が戻ったら「iCloudと同期」で送れます。"
        case .needsReview:
            "両方の作品版を保ったまま保存しています。内容を確認して統合できます。"
        case .configurationError:
            "作品はこの端末に保存されています。iCloudアカウントまたは同期設定を確認してください。"
        case .syncPreparationError:
            "作品はこの端末に保存されています。同期準備を次の保存または再起動時に再試行します。"
        case .localSaveError:
            "この端末への保存を完了できませんでした。保存を再試行してください。"
        }
    }
}

struct IOSDeviceSyncConflictResolutionView: View {
    let conflict: EpisodeConflict
    let state: IOSDeviceSyncUIState
    let resolve: (EpisodeIntegrationChoice) -> Void

    @State private var manualContent: String
    private let draft: IOSDeviceSyncConflictDraft

    init(
        conflict: EpisodeConflict,
        state: IOSDeviceSyncUIState,
        recoveredContent: String? = nil,
        resolve: @escaping (EpisodeIntegrationChoice) -> Void
    ) {
        self.conflict = conflict
        self.state = state
        self.resolve = resolve
        let draft = IOSDeviceSyncConflictDraft(
            conflict: conflict,
            recoveredContent: recoveredContent
        )
        self.draft = draft
        _manualContent = State(initialValue: draft.content)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("このiPhoneともう一方の端末の本文をどちらも残したまま、統合する内容を確認できます。")
                        .foregroundStyle(.secondary)

                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(alignment: .top, spacing: 12) {
                            revisionPanel(title: "共通版", content: conflict.base?.content ?? "共通版はありません")
                            revisionPanel(title: "このiPhone", content: conflict.local.content)
                            revisionPanel(title: "もう一方の端末", content: conflict.remote.content)
                        }
                    }

                    Text(draft.title)
                        .font(.headline)
                    Text(draft.message)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $manualContent)
                        .font(.body.monospaced())
                        .frame(minHeight: 220)
                        .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator) }

                    Button("このiPhoneを採用") { resolve(.keepLocal) }
                        .buttonStyle(.bordered)
                    Button("もう一方を採用") { resolve(.keepRemote) }
                        .buttonStyle(.bordered)
                    Button("手動で統合") { resolve(.manual(content: manualContent)) }
                        .buttonStyle(.borderedProminent)

                    if isResolving {
                        ProgressView("2つの変更を統合しています")
                    }
                }
                .padding()
            }
            .navigationTitle("変更の確認が必要です")
            .navigationBarTitleDisplayMode(.inline)
        }
        .disabled(isResolving)
    }

    private var isResolving: Bool {
        state == .syncing || state == .forcing
    }

    private func revisionPanel(title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            ScrollView {
                Text(content)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(8)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(width: 280, height: 260)
    }
}

struct IOSDeviceSyncLocalRecoveryReviewView: View {
    let review: IOSDeviceSyncLocalRecoveryReview
    let currentContent: String
    let resolve: (IOSDeviceSyncLocalRecoveryChoice) -> Void

    @State private var manualContent: String

    init(
        review: IOSDeviceSyncLocalRecoveryReview,
        currentContent: String,
        resolve: @escaping (IOSDeviceSyncLocalRecoveryChoice) -> Void
    ) {
        self.review = review
        self.currentContent = currentContent
        self.resolve = resolve
        _manualContent = State(initialValue: currentContent)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("端末内に複数の本文が残っています。すべて保持したまま、続きを書く本文を選べます。")
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            revisionPanel(title: "現在の本文", content: currentContent)
                            if review.packageContent != currentContent {
                                revisionPanel(title: "復旧開始時の本文", content: review.packageContent)
                            }
                            ForEach(Array(review.preservedMarkers.enumerated()), id: \.offset) { index, marker in
                                revisionPanel(title: "保存されていた本文 \(index + 1)", content: marker.content)
                            }
                        }
                    }
                    Text("確認用下書き")
                        .font(.headline)
                    TextEditor(text: $manualContent)
                        .font(.body.monospaced())
                        .frame(minHeight: 220)
                        .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator) }
                    Button("現在の本文を採用") { resolve(.current) }
                        .buttonStyle(.bordered)
                    if review.packageContent != currentContent {
                        Button("復旧開始時の本文を採用") { resolve(.packageSnapshot) }
                            .buttonStyle(.bordered)
                    }
                    ForEach(Array(review.preservedMarkers.enumerated()), id: \.offset) { index, marker in
                        Button("保存されていた本文 \(index + 1) を採用") {
                            resolve(.preserved(marker))
                        }
                        .buttonStyle(.bordered)
                    }
                    Button("手動で統合") { resolve(.manual(manualContent)) }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
            }
            .navigationTitle("変更の確認が必要です")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func revisionPanel(title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            ScrollView {
                Text(content)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(8)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(width: 280, height: 260)
    }
}

struct IOSDeviceSyncSettingsView: View {
    let store: IOSDocumentStore

    var body: some View {
        if store.deviceSyncRuntime?.setup != nil {
            Section(store.usesWholeWorkDeviceSync ? "iCloud 作品同期" : "iCloud 本文同期") {
                if store.usesWholeWorkDeviceSync {
                    Text("作品タイトル、あらすじ、章・話、本文、話メモ、登場人物、プロット、伏線、世界観を同期します。資料、スナップショット、アプリの表示設定はこの端末だけに保存されます。")
                        .foregroundStyle(.secondary)
                } else {
                    Text("同期するのは各話の本文だけです。章構成、話メモ、登場人物、プロット、資料、世界観はこの段階では同期されません。")
                        .foregroundStyle(.secondary)
                }
                Text("開始時点の作品タイトルは、同期作品の表示名としてiCloudに保存されます。")
                    .foregroundStyle(.secondary)

                switch store.deviceSyncSetupState {
                case .configured:
                    Label(
                        store.usesWholeWorkDeviceSync
                            ? "この作品は作品同期に接続されています"
                            : "この作品は本文同期に接続されています",
                        systemImage: "checkmark.icloud"
                    )
                case .idle, .candidates:
                    Button(store.usesWholeWorkDeviceSync ? "この作品の同期を始める" : "この作品の本文同期を始める") {
                        guard let session = store.currentDocumentSessionToken else { return }
                        Task { await store.startDeviceSyncForCurrentDocument(expectedSession: session) }
                    }
                    Button("既存の同期作品を探す") {
                        guard let session = store.currentDocumentSessionToken else { return }
                        Task { await store.loadDeviceSyncWorkCandidates(expectedSession: session) }
                    }
                    candidateList
                case .loading:
                    ProgressView(store.usesWholeWorkDeviceSync ? "作品同期を設定しています" : "本文同期を設定しています")
                case let .unavailable(message):
                    Label(message, systemImage: "exclamationmark.icloud")
                        .foregroundStyle(.orange)
                }
            }
            .task(id: store.currentDocumentSessionToken) {
                guard let session = store.currentDocumentSessionToken else { return }
                await store.refreshDeviceSyncSetupStatus(expectedSession: session)
            }
        }
    }

    @ViewBuilder
    private var candidateList: some View {
        if case let .candidates(candidates) = store.deviceSyncSetupState {
            if candidates.isEmpty {
                Text("同じ章・話構成の同期作品は見つかりませんでした。")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(candidates, id: \.workID) { candidate in
                    Button(candidate.title.isEmpty ? "名称未設定の作品" : candidate.title) {
                        guard let session = store.currentDocumentSessionToken else { return }
                        Task {
                            await store.bindCurrentDocument(
                                to: candidate.workID,
                                expectedSession: session
                            )
                        }
                    }
                }
            }
        }
    }
}
