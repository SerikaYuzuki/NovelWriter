import NovelSync
import SwiftUI

struct IOSDeviceSyncStatusBanner: View {
    let state: IOSDeviceSyncUIState
    let transferState: IOSDeviceSyncTransferState
    let identity: IOSDeviceSyncEpisodeIdentity?
    let forceContinue: (IOSDeviceSyncEpisodeIdentity) -> Void

    @State private var forceConfirmationIdentity: IOSDeviceSyncEpisodeIdentity?

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
                    .font(.callout)
                Spacer(minLength: 8)
                if state == .readOnly {
                    Button("このiPhoneで強制的に続ける") {
                        forceConfirmationIdentity = identity
                    }
                        .disabled(identity == nil)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityIdentifier("ios.deviceSync.forceContinue")
                }
            }
            .foregroundStyle(presentation.isWarning ? .orange : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityIdentifier("ios.deviceSync.status")
            .confirmationDialog(
                "このiPhoneで強制的に続けますか？",
                isPresented: forceConfirmationIsPresented,
                titleVisibility: .visible
            ) {
                Button("このiPhoneで強制的に続ける", role: .destructive) {
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
                Presentation(message: "変更をこのiPhone内へ保存しています", systemImage: "internaldrive")
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
            Presentation(message: "このiPhoneへ編集権限を切り替えています", systemImage: "arrow.triangle.2.circlepath", showsProgress: true)
        case .offlineLocal:
            Presentation(message: "オフラインの変更をこのiPhone内に保存しています", systemImage: "icloud.slash", isWarning: true)
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
                    Text("共通版・このiPhoneの変更・同期先の変更を確認し、残す本文を選びます。統合が保存されるまで閉じません。")
                        .foregroundStyle(.secondary)

                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(alignment: .top, spacing: 12) {
                            revisionPanel(title: "共通版", content: conflict.base?.content ?? "共通版はありません")
                            revisionPanel(title: "このiPhone", content: conflict.local.content)
                            revisionPanel(title: "同期先", content: conflict.remote.content)
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

                    Button("このiPhoneの本文を残す") { resolve(.keepLocal) }
                        .buttonStyle(.bordered)
                    Button("同期先の本文を残す") { resolve(.keepRemote) }
                        .buttonStyle(.bordered)
                    Button("手動統合を保存") { resolve(.manual(content: manualContent)) }
                        .buttonStyle(.borderedProminent)

                    if isResolving {
                        ProgressView("2つの変更を統合しています")
                    }
                }
                .padding()
            }
            .navigationTitle("本文の競合を統合")
            .navigationBarTitleDisplayMode(.inline)
        }
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
        .frame(width: 280, height: 260)
    }
}

struct IOSDeviceSyncSettingsView: View {
    let store: IOSDocumentStore

    var body: some View {
        if store.deviceSyncRuntime?.setup != nil {
            Section("iCloud 本文同期") {
                Text("同期するのは各話の本文だけです。章構成、話メモ、登場人物、プロット、資料、世界観はこの段階では同期されません。")
                    .foregroundStyle(.secondary)
                Text("開始時点の作品タイトルは、同期作品の表示名としてiCloudに保存されます。")
                    .foregroundStyle(.secondary)

                switch store.deviceSyncSetupState {
                case .configured:
                    Label("この作品は本文同期に接続されています", systemImage: "checkmark.icloud")
                case .idle, .candidates:
                    Button("この作品の本文同期を始める") {
                        guard let session = store.currentDocumentSessionToken else { return }
                        Task { await store.startDeviceSyncForCurrentDocument(expectedSession: session) }
                    }
                    Button("既存の同期作品を探す") {
                        guard let session = store.currentDocumentSessionToken else { return }
                        Task { await store.loadDeviceSyncWorkCandidates(expectedSession: session) }
                    }
                    candidateList
                case .loading:
                    ProgressView("本文同期を設定しています")
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
