import NovelSync
import SwiftUI

struct DeviceSyncStatusBanner: View {
    let state: DeviceSyncUIState
    let transferState: DeviceSyncTransferState
    let identity: DeviceSyncEpisodeIdentity?
    let forceContinue: (DeviceSyncEpisodeIdentity) -> Void

    @State private var forceConfirmationIdentity: DeviceSyncEpisodeIdentity?

    var body: some View {
        if let presentation {
            HStack(spacing: 8) {
                if presentation.showsProgress {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: presentation.systemImage)
                }
                Text(presentation.message)
                Spacer()
                if state == .readOnly {
                    Button("このMacで続ける") {
                        forceConfirmationIdentity = identity
                    }
                        .disabled(identity == nil)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityIdentifier("deviceSync.forceContinue")
                }
            }
            .font(.callout)
            .foregroundStyle(presentation.isWarning ? .orange : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityIdentifier("deviceSync.status")
            .confirmationDialog(
                "このMacで強制的に続けますか？",
                isPresented: forceConfirmationIsPresented,
                titleVisibility: .visible
            ) {
                Button("このMacで強制的に続ける", role: .destructive) {
                    guard let expectedIdentity = forceConfirmationIdentity else { return }
                    forceConfirmationIdentity = nil
                    forceContinue(expectedIdentity)
                }
                Button("キャンセル", role: .cancel) {
                    forceConfirmationIdentity = nil
                }
            } message: {
                Text("別の端末には、まだ同期されていない本文が残っている可能性があります。その本文は失わずに保管し、あとで統合できるようにします。")
            }
            .onChange(of: identity) { _, currentIdentity in
                guard forceConfirmationIdentity != currentIdentity else { return }
                forceConfirmationIdentity = nil
            }
            .onChange(of: state) { _, currentState in
                guard currentState != .readOnly else { return }
                forceConfirmationIdentity = nil
            }
        }
    }

    private var forceConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: { forceConfirmationIdentity != nil },
            set: { isPresented in
                if !isPresented {
                    forceConfirmationIdentity = nil
                }
            }
        )
    }

    private var presentation: Presentation? {
        switch state {
        case .unconfigured:
            nil
        case .writer:
            switch transferState {
            case .notApplicable:
                nil
            case .localPending:
                Presentation(message: "変更を端末内へ保存しています", systemImage: "internaldrive")
            case .uploading:
                Presentation(message: "本文を同期しています", systemImage: "arrow.up.icloud", showsProgress: true)
            case .upToDate:
                Presentation(message: "本文は同期済みです", systemImage: "checkmark.icloud")
            }
        case .episodeNotIncluded:
            Presentation(message: "この話は本文同期の対象外です", systemImage: "iphone.slash", isWarning: true)
        case .readOnly:
            Presentation(message: "別端末で編集中", systemImage: "lock.fill", isWarning: true)
        case .forcing:
            Presentation(message: "編集権限を切り替えています", systemImage: "arrow.triangle.2.circlepath", showsProgress: true)
        case .offlineLocal:
            Presentation(message: "オフラインの変更を端末内に保存しています", systemImage: "icloud.slash", isWarning: true)
        case .conflict:
            Presentation(message: "本文の競合を統合してください", systemImage: "arrow.triangle.branch", isWarning: true)
        case .syncing:
            Presentation(message: "同期を確認しています", systemImage: "arrow.triangle.2.circlepath", showsProgress: true)
        case .blocked:
            Presentation(message: "同期を確認できません。本文は読み取り専用です", systemImage: "exclamationmark.icloud", isWarning: true)
        }
    }

    private struct Presentation {
        let message: String
        let systemImage: String
        var showsProgress = false
        var isWarning = false
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
            Text("本文の競合を統合")
                .font(.title2)
            Text("共通版・この端末の変更・同期先の変更を確認し、残す本文を選んでください。統合が同期先へ保存されるまでこの画面は閉じません。")
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 12) {
                revisionPanel(title: "共通版", content: conflict.base?.content ?? "共通版はありません")
                revisionPanel(title: "この端末", content: conflict.local.content)
                revisionPanel(title: "同期先", content: conflict.remote.content)
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
                Button("この端末を残す") { resolve(.keepLocal) }
                Button("同期先を残す") { resolve(.keepRemote) }
                Spacer()
                Button("手動統合を保存") { resolve(.manual(content: manualContent)) }
                    .buttonStyle(.borderedProminent)
            }
            .disabled(isResolving)

            if isResolving {
                ProgressView("2つの変更を統合しています")
            }
        }
        .padding(20)
        .frame(minWidth: 920, minHeight: 620)
        .interactiveDismissDisabled()
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

struct DeviceSyncSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.deviceSyncRuntime?.setup != nil {
            VStack(alignment: .leading, spacing: 12) {
                Label("iCloud 本文同期", systemImage: "icloud")
                    .font(.headline)
                Text("同期するのは各話の本文だけです。章構成、話メモ、登場人物、プロット、資料、世界観はこの段階では同期されません。")
                    .foregroundStyle(.secondary)
                Text("開始時点の作品タイトルは、同期作品の表示名としてiCloudに保存されます。")
                    .foregroundStyle(.secondary)
                Text("外部ファイルを開いている場合は、同期を始める前に作品全体をこのMac内の専用作業コピーへ複製し、そちらへ切り替えます。元ファイルは変更しません。")
                    .foregroundStyle(.secondary)

                switch appState.deviceSyncSetupState {
                case .configured:
                    Label("この作品は本文同期に接続されています", systemImage: "checkmark.icloud")
                case .idle, .candidates:
                    Button("この作品の本文同期を始める") {
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
                    ProgressView("本文同期を設定しています")
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
