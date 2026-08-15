import AppKit
import SwiftUI

struct StartupLoadingView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.book.closed")
                .font(.largeTitle.weight(.light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("ふみにわ")
                    .font(.title2.weight(.semibold))
                Text("作品を準備しています…")
                    .foregroundStyle(.secondary)
            }

            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("作品を準備中")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 640, minHeight: 420)
        .background(.background)
    }
}

struct StartupDocumentSelectionView: View {
    @Environment(AppState.self) private var appState
    @Environment(DocumentPanelPresenter.self) private var documentPanelPresenter

    let context: StartupDocumentSelectionContext

    @State private var selectedWorkID: StartupLibraryWork.ID?
    @State private var pendingLocalRemoval: StartupLibraryWork?
    @FocusState private var isLibraryFocused: Bool

    init(context: StartupDocumentSelectionContext) {
        self.context = context
        _selectedWorkID = State(initialValue: context.works.first?.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            welcomeActions
            library
        }
        .frame(minWidth: 720, minHeight: 520)
        .background(.background)
        .disabled(appState.isStartupLibraryOperationInProgress)
        .overlay(alignment: .topTrailing) {
            if appState.isStartupLibraryOperationInProgress {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("作品を準備しています…")
                        .font(.caption)
                }
                .padding(16)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("startup.documentSelection.operationProgress")
            }
        }
        .accessibilityIdentifier("startup.documentSelection")
        .onKeyPress(.return) {
            // 上部action buttonがkeyboard focus中なら、そのButton自身へReturnを渡す。
            guard isLibraryFocused, selectedWork != nil else { return .ignored }
            openSelectedWork()
            return .handled
        }
        .onKeyPress(.delete) {
            guard isLibraryFocused,
                  let work = selectedWork,
                  work.availability.canRemoveLocalCopy else { return .ignored }
            pendingLocalRemoval = work
            return .handled
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(
                get: { pendingLocalRemoval != nil },
                set: {
                    if !$0 {
                        pendingLocalRemoval = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("削除", role: .destructive) {
                guard let work = pendingLocalRemoval else { return }
                let session = appState.documentSessionToken
                pendingLocalRemoval = nil
                Task {
                    _ = await appState.removeLocalStartupLibraryWork(
                        work.reference,
                        expectedSession: session
                    )
                }
            }
            Button("キャンセル", role: .cancel) {
                pendingLocalRemoval = nil
            }
        } message: {
            Text(deletionMessage)
        }
    }

    private var welcomeActions: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)

                Text("ふみにわ")
                    .font(.title2.weight(.semibold))
            }

            HStack(spacing: 12) {
                Button {
                    documentPanelPresenter.presentOpenPanel(
                        expectedSession: appState.documentSessionToken
                    )
                } label: {
                    Label("作品を取り込む…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .disabled(!appState.permitsCloudLibraryMutation)
                .accessibilityIdentifier("startup.documentSelection.import")

                Button {
                    documentPanelPresenter.presentNewDocument(
                        expectedSession: appState.documentSessionToken
                    )
                } label: {
                    Label("新しい作品", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!appState.permitsCloudLibraryMutation)
                .accessibilityIdentifier("startup.documentSelection.new")
            }

            FuminiwaAuthStatusView()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 32)
        .padding(.bottom, 24)
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(context.presentation == .cloudLibrary ? "iCloudの作品" : "最近使った作品")
                    .font(.headline)

                Spacer()

                if context.isLoading, !context.works.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("iCloudの作品を更新中")
                }

                connectionStatus
            }

            Group {
                if context.isLoading, context.works.isEmpty {
                    ProgressView("iCloudの作品を確認しています")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if context.works.isEmpty {
                    ContentUnavailableView(
                        emptyTitle,
                        systemImage: emptySystemImage,
                        description: Text(emptyDescription)
                    )
                } else {
                    List(selection: $selectedWorkID) {
                        ForEach(context.works) { work in
                            StartupLibraryWorkRow(
                                work: work,
                                connection: context.connection
                            )
                            .tag(work.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                selectedWorkID = work.id
                                openSelectedWork(work)
                            }
                            .contextMenu {
                                libraryContextMenu(for: work)
                            }
                            .accessibilityIdentifier("startup.documentSelection.work")
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .focused($isLibraryFocused)
                    .accessibilityIdentifier("startup.documentSelection.library")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.separator, lineWidth: 1)
            }

            if context.presentation == .cloudLibrary {
                Text("資料とスナップショット履歴はこのMacに保存されます")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 40)
        .padding(.bottom, 32)
        .frame(maxWidth: 880, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var connectionStatus: some View {
        switch context.connection {
        case .available:
            EmptyView()
        case .offline:
            Label("オフライン", systemImage: "icloud.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .accountRequired:
            Label("iCloudの設定を確認", systemImage: "exclamationmark.icloud")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .differentAccount:
            Label("iCloudアカウントが異なります", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .unavailable:
            Label("読み込めませんでした", systemImage: "exclamationmark.icloud")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var selectedWork: StartupLibraryWork? {
        context.works.first { $0.id == selectedWorkID }
    }

    @ViewBuilder
    private func libraryContextMenu(for work: StartupLibraryWork) -> some View {
        if work.availability == .needsReview {
            Button("変更を確認") {
                selectedWorkID = work.id
                openSelectedWork(work)
            }
        }
        if work.availability.canPublishToCloud(connection: context.connection) {
            Button("iCloudに保存") {
                publishWork(work)
            }
            .disabled(!appState.permitsCloudLibraryMutation)
        }
        if work.availability.canDuplicateLocalCopy {
            Button("複製") {
                duplicateWork(work)
            }
            .disabled(!appState.permitsCloudLibraryMutation)
        }
        if work.availability.canRemoveLocalCopy {
            Button("このMacから削除", role: .destructive) {
                pendingLocalRemoval = work
            }
            .disabled(!appState.permitsCloudLibraryMutation)
        }
    }

    private func publishWork(_ work: StartupLibraryWork) {
        let session = appState.documentSessionToken
        Task {
            _ = await appState.publishStartupLibraryWork(
                work.reference,
                expectedSession: session
            )
        }
    }

    private func duplicateWork(_ work: StartupLibraryWork) {
        let session = appState.documentSessionToken
        Task {
            _ = await appState.duplicateStartupLibraryWork(
                work.reference,
                expectedSession: session
            )
        }
    }

    private var deletionTitle: String {
        "この作品を削除しますか？"
    }

    private var deletionMessage: String {
        switch pendingLocalRemoval?.availability {
        case .cachedRemote, .needsReview, .cloudUnavailable:
            "このMacの作業コピーを削除します。iCloud上の作品は消えません。"
        default:
            "このMacの作品を削除します。元に戻せません。"
        }
    }

    private func openSelectedWork(_ work: StartupLibraryWork? = nil) {
        guard let work = work ?? selectedWork else { return }
        if !work.availability.isOpenable(connection: context.connection) {
            return
        }
        let session = appState.documentSessionToken
        Task {
            _ = await appState.openStartupLibraryWork(
                work.reference,
                expectedSession: session
            )
        }
    }

    private var emptyTitle: String {
        switch context.connection {
        case .accountRequired:
            "iCloudを利用できません"
        case .differentAccount:
            "別のiCloudアカウントです"
        case .unavailable:
            "作品を読み込めませんでした"
        case .available, .offline:
            "作品がありません"
        }
    }

    private var emptySystemImage: String {
        switch context.connection {
        case .accountRequired, .differentAccount, .unavailable:
            "exclamationmark.icloud"
        case .available, .offline:
            "books.vertical"
        }
    }

    private var emptyDescription: String {
        switch context.connection {
        case .available:
            "新しい作品を作るか、作品パッケージを取り込めます。"
        case .offline:
            "接続後にiCloudの作品を確認できます。"
        case .accountRequired:
            "システム設定でiCloud Driveを確認してください。"
        case .differentAccount:
            "このMacにある作品は開けますが、このアカウントへ自動では送信しません。"
        case let .unavailable(message):
            message
        }
    }
}

private struct FuminiwaAuthStatusView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 10) {
            Label(appState.authUIState.label, systemImage: iconName)
                .font(.caption)
                .foregroundStyle(.secondary)

            switch appState.authUIState {
            case .signedOut, .failed:
                Button("Appleでサインイン") {
                    Task { await appState.signInWithApple() }
                }
                .buttonStyle(.bordered)
                .disabled(appState.authUIState == .signingIn)
                .accessibilityIdentifier("auth.signInWithApple")
            case .signingIn:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Appleでサインイン中")
            case .signedIn:
                Button("サインアウト") {
                    Task { await appState.signOutFromFuminiwa() }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("auth.signOut")
            case .unavailable:
                EmptyView()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("auth.status")
    }

    private var iconName: String {
        switch appState.authUIState {
        case .signedIn:
            "person.crop.circle.fill"
        case .signingIn:
            "arrow.triangle.2.circlepath.circle"
        case .failed:
            "exclamationmark.triangle"
        case .signedOut, .unavailable:
            "person.crop.circle"
        }
    }
}

private struct StartupLibraryWorkRow: View {
    @Environment(AppState.self) private var appState
    let work: StartupLibraryWork
    let connection: StartupLibraryConnection

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "book.closed")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(work.displayTitle)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if let updatedAt = work.updatedAt {
                        Text(updatedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    Label(availabilityLabel, systemImage: availabilitySystemImage)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            if work.availability == .needsReview {
                Button("変更を確認") {
                    let session = appState.documentSessionToken
                    Task {
                        _ = await appState.openStartupLibraryWork(
                            work.reference,
                            expectedSession: session
                        )
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(appState.isStartupLibraryOperationInProgress)
                .accessibilityIdentifier("startup.documentSelection.review")
            } else if work.availability.canPublishToCloud(connection: connection) {
                Button("iCloudに保存") {
                    let session = appState.documentSessionToken
                    Task {
                        _ = await appState.publishStartupLibraryWork(
                            work.reference,
                            expectedSession: session
                        )
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(
                    !appState.permitsCloudLibraryMutation
                        || appState.isStartupLibraryOperationInProgress
                )
                .accessibilityIdentifier("startup.documentSelection.publish")
            }
        }
        .padding(.vertical, 4)
        .opacity(isUnavailable ? 0.6 : 1)
        .accessibilityElement(
            children: work.availability == .needsReview
                || work.availability.canPublishToCloud(connection: connection)
                ? .contain
                : .ignore
        )
        .accessibilityLabel(work.displayTitle)
        .accessibilityValue(availabilityLabel)
        .accessibilityHint(accessibilityHint)
        .accessibilityRespondsToUserInteraction(!isUnavailable)
    }

    private var availabilityLabel: String {
        switch work.availability {
        case .cachedRemote where connection == .available:
            "作品データをiCloudと同期済み"
        case .cachedRemote where connection == .offline:
            "このMacに保存済み、オフラインでも開けます"
        case .cachedRemote where connection == .differentAccount:
            "このMacに保存済み、iCloudアカウントが異なります"
        case .cachedRemote:
            "このMacに保存済み、iCloud設定を確認"
        case .localPending where connection == .available:
            "このMacに保存済み、iCloudへ保存中"
        case .localPending where connection == .accountRequired:
            "このMacに保存済み、iCloud設定を確認"
        case .localPending where connection == .differentAccount:
            "このMacに保存済み、iCloudアカウントが異なります"
        case .localPending where connection == .offline:
            "このMacに保存済み、接続後に同期"
        case .localPending:
            "このMacに保存済み、iCloudへ再送できます"
        case .localOnly:
            "このMacにのみ保存済み"
        case .needsReview:
            "このMacに保存済み、変更の確認が必要"
        case .cloudUnavailable:
            "このMacに保存済み、iCloud上の状態を確認できません"
        case .remotePending:
            "このMacへの保存を再開"
        case .remoteOnly where connection == .available:
            "iCloudからダウンロード"
        case .remoteOnly:
            "ダウンロードには接続が必要"
        case .unavailable:
            "このMacのコピーを確認できません"
        }
    }

    private var availabilitySystemImage: String {
        switch work.availability {
        case .cachedRemote where connection == .available:
            "checkmark.icloud"
        case .cachedRemote:
            "icloud.slash"
        case .localPending where connection == .available:
            "arrow.triangle.2.circlepath.icloud"
        case .localPending:
            "icloud.slash"
        case .localOnly:
            "externaldrive"
        case .needsReview:
            "exclamationmark.triangle"
        case .cloudUnavailable:
            "exclamationmark.icloud"
        case .remotePending:
            "arrow.clockwise.icloud"
        case .remoteOnly where connection == .available:
            "icloud.and.arrow.down"
        case .remoteOnly:
            "icloud.slash"
        case .unavailable:
            "exclamationmark.triangle"
        }
    }

    private var accessibilityHint: String {
        switch work.availability {
        case .remoteOnly where connection != .available:
            return "接続後にReturnキーまたはダブルクリックで開けます。"
        case .cloudUnavailable:
            return "iCloud上の状態を確認できるまで、この作品は開きません。端末内のコピーは変更していません。"
        case .unavailable:
            return "この作品は安全に開けません。iCloud設定または作品パッケージを確認してください。"
        case .localOnly:
            return "iCloudとは関連付けられていません。iCloudに保存、複製、削除はメニューから選べます。Returnキーまたはダブルクリックで開きます。"
        case .needsReview:
            return "この端末とiCloudの内容が違います。「変更を確認」から残す側を選べます。"
        case .cachedRemote, .localPending, .remoteOnly, .remotePending:
            let action = "Returnキーまたはダブルクリックで開きます。"
            return work.isTitleTruncated ? "作品名は省略表示されています。" + action : action
        }
    }

    private var isUnavailable: Bool {
        !work.availability.isOpenable(connection: connection)
    }
}

private extension StartupLibraryWorkAvailability {
    func isOpenable(connection: StartupLibraryConnection) -> Bool {
        switch self {
        case .cachedRemote, .localPending, .localOnly, .remotePending, .needsReview:
            true
        case .remoteOnly:
            connection == .available
        case .cloudUnavailable, .unavailable:
            false
        }
    }
}

struct StartupRecoveryView: View {
    @Environment(AppState.self) private var appState
    @Environment(DocumentPanelPresenter.self) private var documentPanelPresenter

    let context: StartupRecoveryContext

    @State private var confirmsNewDocument = false
    @State private var newDocumentSession: DocumentSessionToken?

    var body: some View {
        VStack(spacing: 20) {
            ContentUnavailableView(
                title,
                systemImage: "book.closed.fill",
                description: Text(message)
            )

            HStack(spacing: 10) {
                if context.reason != .protectedLocationInDebugBuild,
                   context.reason != .deviceSyncSafetyUnavailable {
                    Button("再試行") {
                        Task { await appState.retryStartup() }
                    }
                    .keyboardShortcut(.defaultAction)
                }

                if let finderURL {
                    Button(finderButtonTitle) {
                        NSWorkspace.shared.activateFileViewerSelecting([finderURL])
                    }
                }

                if context.reason != .deviceSyncSafetyUnavailable {
                    Button("別の作品を開く…") {
                        documentPanelPresenter.presentOpenPanel()
                    }

                    Button("新規作品を作る…") {
                        newDocumentSession = appState.documentSessionToken
                        confirmsNewDocument = true
                    }
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 680, minHeight: 440)
        .background(.background)
        .confirmationDialog(
            "新しい作品を作りますか？",
            isPresented: $confirmsNewDocument
        ) {
            Button("新規作品を作る") {
                guard let newDocumentSession else { return }
                documentPanelPresenter.presentNewDocument(expectedSession: newDocumentSession)
                self.newDocumentSession = nil
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("開けなかった作品は変更も削除もしません。新しい作品を保存できた後に、そちらへ切り替えます。")
        }
    }

    private var title: String {
        switch context.reason {
        case .cannotOpenDocument:
            "作品を安全に開けませんでした"
        case .cannotCreateDocument:
            "新しい作品を保存できませんでした"
        case .protectedLocationInDebugBuild:
            "開発版で実原稿を自動では開きません"
        case .deviceSyncSafetyUnavailable:
            "本文同期の安全情報を確認できません"
        }
    }

    private var finderURL: URL? {
        // Finder/Open Withで利用者が明示した外部原本だけをFinderへ戻せる。
        // app-private working copyやcloud bootstrap URLはUIへ露出しない。
        guard context.source == .finder else { return nil }
        guard let documentURL = context.documentURL else { return nil }
        if context.reason == .cannotCreateDocument {
            return documentURL.deletingLastPathComponent()
        }
        return documentURL
    }

    private var finderButtonTitle: String {
        context.reason == .cannotCreateDocument ? "保存先を Finder で表示" : "Finder で表示"
    }

    private var message: String {
        switch context.reason {
        case .cannotOpenDocument:
            if context.source == .finder, let name = context.documentDisplayName {
                "「\(name)」は変更していません。再試行するか、Finder で原本を確認してください。"
            } else {
                "端末内の作品は変更していません。再試行するか、作品一覧へ戻ってください。"
            }
        case .cannotCreateDocument:
            "保存先の空き容量やアクセス権限を確認してください。保存に成功するまで最近使った作品は変更しません。"
        case .protectedLocationInDebugBuild:
            "実原稿への誤保存を防ぐためです。内容を確認したうえで「別の作品を開く…」から明示的に選んでください。"
        case .deviceSyncSafetyUnavailable:
            "以前同期した作品を誤って編集しないよう停止しました。アプリを再起動しても直らない場合は、端末の空き容量とiCloud設定を確認してください。"
        }
    }
}
