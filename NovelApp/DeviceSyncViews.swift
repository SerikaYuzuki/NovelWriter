import NovelSync
import SwiftUI

struct DeviceSyncStatusControl: View {
    let saveState: DocumentSaveState
    let state: DeviceSyncUIState
    let transferState: DeviceSyncTransferState
    let localDurabilityState: DeviceSyncLocalDurabilityState
    let hasLocalRecoveryReview: Bool
    let isLocalRecoveryReviewReady: Bool
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
        .buttonStyle(.plain)
        .foregroundStyle(resolvedStatus.isWarning ? .orange : .secondary)
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .help(resolvedStatus.accessibilityLabel)
        .accessibilityLabel(resolvedStatus.accessibilityLabel)
        .accessibilityHint(resolvedStatus == .needsReview ? "変更内容を確認します" : "保存と同期の詳細を表示します")
        .accessibilityIdentifier("deviceSync.status")
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Label(resolvedStatus.accessibilityLabel, systemImage: resolvedStatus.systemImage)
                    .font(.headline)
                Text(resolvedStatus.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(width: 300, alignment: .leading)
        }
        .onChange(of: resolvedStatus) { _, current in
            if current == .needsReview {
                showsDetails = false
            }
        }
    }

    var resolvedStatus: DeviceSyncEditorStatusKind {
        let base = DeviceSyncEditorStatusKind.resolve(
            saveState: saveState,
            syncState: state,
            transferState: transferState,
            localDurability: localDurabilityState
        )
        if hasLocalRecoveryReview, !isLocalRecoveryReviewReady {
            return base == .localSaveError ? .localSaveError : .savingLocally
        }
        if hasLocalRecoveryReview, base != .localSaveError, base != .savingLocally {
            return .needsReview
        }
        return base
    }
}

struct DeviceSyncConflictResolutionView: View {
    let conflict: EpisodeConflict
    let state: DeviceSyncUIState
    let resolve: (EpisodeIntegrationChoice) -> Void

    @State private var manualContent: String
    private let draft: DeviceSyncConflictDraft

    init(
        conflict: EpisodeConflict,
        state: DeviceSyncUIState,
        recoveredContent: String? = nil,
        resolve: @escaping (EpisodeIntegrationChoice) -> Void
    ) {
        self.conflict = conflict
        self.state = state
        self.resolve = resolve
        let draft = DeviceSyncConflictDraft(
            conflict: conflict,
            recoveredContent: recoveredContent
        )
        self.draft = draft
        _manualContent = State(initialValue: draft.content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("変更の確認が必要です")
                .font(.title2)
            Text("この端末ともう一方の端末の本文をどちらも残したまま、統合する内容を確認できます。")
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 12) {
                revisionPanel(title: "共通版", content: conflict.base?.content ?? "共通版はありません")
                revisionPanel(title: "この端末", content: conflict.local.content)
                revisionPanel(title: "もう一方の端末", content: conflict.remote.content)
            }

            Text(draft.title)
                .font(.headline)
            Text(draft.message)
                .foregroundStyle(.secondary)
            TextEditor(text: $manualContent)
                .font(.body.monospaced())
                .frame(minHeight: 160)
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator) }

            HStack {
                Button("この端末を採用") { resolve(.keepLocal) }
                Button("もう一方を採用") { resolve(.keepRemote) }
                Spacer()
                Button("手動で統合") { resolve(.manual(content: manualContent)) }
                    .buttonStyle(.borderedProminent)
            }
            .disabled(isResolving)

            if isResolving {
                ProgressView("2つの変更を統合しています")
            }
        }
        .padding(20)
        .frame(minWidth: 920, minHeight: 620)
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
        .frame(maxWidth: .infinity, minHeight: 220)
    }
}

struct DeviceSyncLocalRecoveryReviewView: View {
    let review: DeviceSyncLocalRecoveryReview
    let currentContent: String
    let resolve: (DeviceSyncLocalRecoveryChoice) -> Void

    @State private var manualContent: String

    init(
        review: DeviceSyncLocalRecoveryReview,
        currentContent: String,
        resolve: @escaping (DeviceSyncLocalRecoveryChoice) -> Void
    ) {
        self.review = review
        self.currentContent = currentContent
        self.resolve = resolve
        _manualContent = State(initialValue: currentContent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("変更の確認が必要です")
                .font(.title2)
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
                .frame(minHeight: 160)
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator) }

            HStack {
                Button("現在の本文を採用") { resolve(.current) }
                if review.packageContent != currentContent {
                    Button("復旧開始時の本文を採用") { resolve(.packageSnapshot) }
                }
                Menu("保存されていた本文を採用") {
                    ForEach(Array(review.preservedMarkers.enumerated()), id: \.offset) { index, marker in
                        Button("本文 \(index + 1)") { resolve(.preserved(marker)) }
                    }
                }
                Spacer()
                Button("手動で統合") { resolve(.manual(manualContent)) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 920, minHeight: 620)
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
        .frame(width: 280, height: 240)
    }
}

struct DeviceSyncSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.deviceSyncRuntime?.setup != nil {
            VStack(alignment: .leading, spacing: 12) {
                Label(syncHeading, systemImage: "icloud")
                    .font(.headline)
                Text(syncScopeDescription)
                    .foregroundStyle(.secondary)
                Text("開始時点の作品タイトルは、同期作品の表示名としてiCloudに保存されます。")
                    .foregroundStyle(.secondary)
                Text("外部ファイルを開いている場合は、同期を始める前に作品全体をこのMac内の専用作業コピーへ複製し、そちらへ切り替えます。元ファイルは変更しません。")
                    .foregroundStyle(.secondary)

                switch appState.deviceSyncSetupState {
                case .configured:
                    Label(configuredDescription, systemImage: "checkmark.icloud")
                case .idle, .candidates:
                    Button(startButtonTitle) {
                        let session = appState.documentSessionToken
                        Task {
                            await appState.startDeviceSyncForCurrentDocument(expectedSession: session)
                        }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("既存の同期作品を探す") {
                        let session = appState.documentSessionToken
                        Task { await appState.loadDeviceSyncWorkCandidates(expectedSession: session) }
                    }

                    candidateList
                case .loading:
                    ProgressView(setupProgressTitle)
                case let .unavailable(message):
                    Label(message, systemImage: "exclamationmark.icloud")
                        .foregroundStyle(.orange)
                }
            }
            .task(id: appState.documentSessionToken) {
                await appState.refreshDeviceSyncSetupStatus(
                    expectedSession: appState.documentSessionToken
                )
            }
        }
    }

    private var usesWholeWorkSync: Bool {
        appState.deviceSyncRuntime?.workTransport != nil
    }

    private var syncHeading: String {
        usesWholeWorkSync ? "iCloud 作品同期" : "iCloud 本文同期"
    }

    private var syncScopeDescription: String {
        if usesWholeWorkSync {
            return "作品タイトル、あらすじ、章・話構成、本文、話メモ、登場人物、プロット、伏線、世界観を同期します。資料、スナップショット、アプリの表示設定はこの端末だけに保存されます。"
        }
        return "同期するのは各話の本文だけです。章構成、話メモ、登場人物、プロット、資料、世界観はこの段階では同期されません。"
    }

    private var configuredDescription: String {
        usesWholeWorkSync ? "この作品は作品同期に接続されています" : "この作品は本文同期に接続されています"
    }

    private var startButtonTitle: String {
        usesWholeWorkSync ? "この作品の同期を始める" : "この作品の本文同期を始める"
    }

    private var setupProgressTitle: String {
        usesWholeWorkSync ? "作品同期を設定しています" : "本文同期を設定しています"
    }

    @ViewBuilder
    private var candidateList: some View {
        if case let .candidates(candidates) = appState.deviceSyncSetupState {
            if candidates.isEmpty {
                Text("同じ章・話構成の同期作品は見つかりませんでした。")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("接続する作品を選ぶ")
                        .font(.subheadline.weight(.semibold))
                    ForEach(candidates, id: \.workID) { candidate in
                        Button(candidate.title.isEmpty ? "名称未設定の作品" : candidate.title) {
                            let session = appState.documentSessionToken
                            Task {
                                await appState.bindCurrentDocument(
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
}
