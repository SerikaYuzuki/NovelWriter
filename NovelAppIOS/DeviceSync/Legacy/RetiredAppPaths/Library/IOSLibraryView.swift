import NovelSync
import SwiftUI

struct IOSLibraryView: View {
    @Bindable var store: IOSDocumentStore
    let openDocument: (IOSPrivateDocumentID) -> Void
    let openCloudDocument: (SyncWorkID) -> Void
    let makeNewDocument: () -> Void

    @State private var pendingLocalRemoval: IOSCloudLibraryItem?

    var body: some View {
        Group {
            if store.usesCloudLibrary, !store.usesSnapshotSyncRuntime {
                cloudLibrary
            } else if store.libraryItems.isEmpty {
                ContentUnavailableView {
                    Label("作品がありません", systemImage: "books.vertical")
                } description: {
                    Text("新しい作品を作るか、Filesから取り込めます。")
                } actions: {
                    Button("新規作品") {
                        makeNewDocument()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Filesから取り込む…") {
                        store.isImporterPresented = true
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                libraryList
            }
        }
        .navigationTitle("作品")
        .navigationBarTitleDisplayMode(.large)
        .safeAreaInset(edge: .top) {
            IOSAccountStatusView(store: store)
                .padding(.horizontal)
                .padding(.top, 8)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                IOSAppearanceMenu()
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("新規作品", systemImage: "doc.badge.plus") {
                        makeNewDocument()
                    }
                    .disabled(store.usesCloudLibrary && !store.permitsCloudLibraryMutation)
                    Button("Filesから取り込む…", systemImage: "folder.badge.plus") {
                        store.isImporterPresented = true
                    }
                    .disabled(store.usesCloudLibrary && !store.permitsCloudLibraryMutation)
                } label: {
                    Label("作品を追加", systemImage: "plus")
                }
                .accessibilityIdentifier("ios.library.add")
            }
        }
        .onAppear {
            // Cloud libraryは起動時にlocal shelfを先に構築し、remote refreshは
            // FuminiwaIOSApp／signal／pull-to-refreshから行う。従来ここでも
            // refreshしていたため、画面表示のたびにCloudKitを再確認していた。
            guard !store.usesCloudLibrary else { return }
            Task {
                _ = await store.refreshLibrary()
            }
        }
    }

    @ViewBuilder
    private var cloudLibrary: some View {
        if store.cloudLibraryItems.isEmpty, !store.cloudLibraryIsLoading {
            ContentUnavailableView {
                Label(cloudEmptyTitle, systemImage: cloudEmptySystemImage)
            } description: {
                Text(cloudEmptyDescription)
            } actions: {
                if store.permitsCloudLibraryMutation {
                    Button("新規作品") {
                        makeNewDocument()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("作品を取り込む…") {
                        store.isImporterPresented = true
                    }
                    .buttonStyle(.bordered)
                }
            }
        } else {
            List {
                if let notice = cloudConnectionNotice {
                    Section {
                        Label(notice, systemImage: "icloud.slash")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    ForEach(store.cloudLibraryItems) { item in
                        IOSCloudLibraryRow(
                            item: item,
                            isCurrent: item.id == store.activeCloudWorkID,
                            connection: store.cloudLibraryConnection
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard canOpen(item) else { return }
                            openCloudDocument(item.id)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            cloudLibrarySwipeActions(for: item)
                        }
                        .contextMenu {
                            cloudLibraryContextMenu(for: item)
                        }
                        .accessibilityIdentifier("ios.cloudLibrary.work")
                        .accessibilityAddTraits(canOpen(item) ? .isButton : [])
                    }
                } header: {
                    Text("サーバーの作品")
                } footer: {
                    Text("作品はサーバーから選びます。この端末の作業コピーはアプリ内で安全に管理され、Filesには表示されません。")
                }
            }
            .overlay {
                // cached/local rowsがある場合はCloudKit更新中も操作を止めない。
                // 初回で棚が空のときだけ確認中表示を出す。
                if store.cloudLibraryIsLoading, store.cloudLibraryItems.isEmpty {
                    ProgressView("サーバーの作品を確認中…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .refreshable {
                await store.refreshCloudLibrary()
            }
            .confirmationDialog(
                "この作品を削除しますか？",
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
                    guard let item = pendingLocalRemoval else { return }
                    pendingLocalRemoval = nil
                    Task {
                        _ = await store.removeLocalCloudLibraryWork(item.id)
                    }
                }
                Button("キャンセル", role: .cancel) {
                    pendingLocalRemoval = nil
                }
            } message: {
                Text(deletionMessage)
            }
        }
    }

    private var libraryList: some View {
        List {
            Section {
                ForEach(store.libraryItems) { item in
                    Button {
                        open(item)
                    } label: {
                        IOSLibraryRow(
                            item: item,
                            isCurrent: item.id.packageName == store.documentURL.lastPathComponent
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ios.library.work.\(item.id.packageName)")
                }
            } header: {
                Text("このデバイスの作品")
            } footer: {
                Text("ここには、ふみにわ内の作業コピーが表示されます。Filesの原本は変更しません。")
            }
        }
        .refreshable {
            await store.refreshLibrary()
        }
    }

    private func open(_ item: IOSDocumentLibraryItem) {
        switch item.availability {
        case .available:
            openDocument(item.id)
        case .unreadable:
            store.operationErrorMessage = item.errorMessage
                ?? "この作業コピーを読み込めませんでした。他の作品はそのまま利用できます。"
        }
    }

    private func canOpen(_ item: IOSCloudLibraryItem) -> Bool {
        switch item.availability {
        case .cachedRemote, .localPending, .localOnly, .accountQuarantined, .needsReview:
            true
        case .legacyLocal:
            store.permitsCloudLibraryMutation
        case .remotePending:
            store.cloudLibraryConnection == .available || store.cloudLibraryConnection == .offline
        case .remoteOnly:
            store.cloudLibraryConnection == .available
        case .cloudUnavailable, .unavailable:
            false
        }
    }

    @ViewBuilder
    private func cloudLibrarySwipeActions(for item: IOSCloudLibraryItem) -> some View {
        if item.availability.canRemoveLocalCopy {
            Button("削除", role: .destructive) {
                pendingLocalRemoval = item
            }
            .disabled(!store.permitsCloudLibraryMutation)
        }
        if item.availability.canDuplicateLocalCopy {
            Button("複製") {
                duplicateWork(item)
            }
            .disabled(!store.permitsCloudLibraryMutation)
        }
    }

    @ViewBuilder
    private func cloudLibraryContextMenu(for item: IOSCloudLibraryItem) -> some View {
        if item.availability.canDuplicateLocalCopy {
            Button("複製") {
                duplicateWork(item)
            }
            .disabled(!store.permitsCloudLibraryMutation)
        }
        if item.availability.canRemoveLocalCopy {
            Button("この端末から削除", role: .destructive) {
                pendingLocalRemoval = item
            }
            .disabled(!store.permitsCloudLibraryMutation)
        }
    }

    private func publishWork(_ item: IOSCloudLibraryItem) {
        Task {
            _ = await store.publishCloudLibraryWork(item.id)
        }
    }

    private func duplicateWork(_ item: IOSCloudLibraryItem) {
        Task {
            _ = await store.duplicateCloudLibraryWork(item.id)
        }
    }

    private var deletionMessage: String {
        switch pendingLocalRemoval?.availability {
        case .cachedRemote, .needsReview, .cloudUnavailable:
            "この端末の作業コピーを削除します。サーバー上の作品は消えません。"
        default:
            "この端末の作品を削除します。元に戻せません。"
        }
    }

    private var cloudConnectionNotice: String? {
        IOSCloudLibraryPresentation.connectionNotice(store.cloudLibraryConnection)
    }

    private var cloudEmptyTitle: String {
        switch store.cloudLibraryConnection {
        case .checking:
            "サーバーを確認中"
        case .accountRequired, .differentAccount:
            "サーバー接続を確認してください"
        case .available, .offline, .unavailable:
            "作品がありません"
        }
    }

    private var cloudEmptyDescription: String {
        switch store.cloudLibraryConnection {
        case .checking:
            "確認が終わるとサーバーの作品を表示します。"
        case .accountRequired:
            "ネットワーク設定を確認してください。"
        case .differentAccount:
            "サインイン中のアカウントを確認してください。"
        case .offline:
            "接続が戻るとサーバーの作品を表示します。"
        case .unavailable:
            "サーバーへ接続できませんでした。下に引いて再読み込みしてください。"
        case .available:
            "新しい作品を作るか、.novelpkgを取り込めます。"
        }
    }

    private var cloudEmptySystemImage: String {
        switch store.cloudLibraryConnection {
        case .checking, .accountRequired, .differentAccount, .unavailable:
            "exclamationmark.triangle"
        case .available, .offline:
            "books.vertical"
        }
    }
}

private struct IOSAccountStatusView: View {
    let store: IOSDocumentStore

    var body: some View {
        HStack(spacing: 10) {
            Label(store.authUIState.label, systemImage: iconName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            switch store.authUIState {
            case .signedOut, .failed:
                Button("Appleでサインイン") {
                    Task { await store.signInWithApple() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("ios.auth.signInWithApple")
            case .signingIn:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Appleでサインイン中")
            case .signedIn:
                Button("サインアウト") {
                    Task { await store.signOutFromFuminiwa() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("ios.auth.signOut")
            case .unavailable:
                EmptyView()
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ios.auth.status")
    }

    private var iconName: String {
        switch store.authUIState {
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

enum IOSCloudLibraryPresentation {
    static func connectionNotice(_ connection: IOSCloudLibraryConnection) -> String? {
        switch connection {
        case .checking:
            "サーバーの状態を確認しています。"
        case .available:
            nil
        case .offline:
            "オフラインです。端末に保存済みの作品は開けます。"
        case .accountRequired:
            "サインインとネットワーク設定を確認してください。"
        case .differentAccount:
            "前回と異なるアカウントです。この端末に保存済みの作品だけを表示し、自動では送信しません。"
        case .unavailable:
            "サーバーの作品を更新できませんでした。端末に保存済みの作品は開けます。"
        }
    }
}

private struct IOSCloudLibraryRow: View {
    let item: IOSCloudLibraryItem
    let isCurrent: Bool
    let connection: IOSCloudLibraryConnection

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .foregroundStyle(iconColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.displayTitle)
                        .foregroundStyle(.primary)
                    if isCurrent {
                        Text("選択中")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let updatedAt = item.updatedAt {
                    Text(updatedAt, format: .dateTime.year().month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)
            if showsChevron {
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.displayTitle)
        .accessibilityValue(isCurrent ? "選択中、\(statusText)" : statusText)
    }

    private var systemImage: String {
        switch item.availability {
        case .cachedRemote where connection == .available:
            "checkmark.circle"
        case .cachedRemote:
            "wifi.slash"
        case .remoteOnly, .remotePending:
            "arrow.down.circle"
        case .localPending where connection == .available:
            "arrow.triangle.2.circlepath"
        case .localPending:
            "wifi.slash"
        case .localOnly:
            "iphone"
        case .accountQuarantined:
            "person.crop.circle.badge.exclamationmark"
        case .legacyLocal:
            "square.and.arrow.down"
        case .needsReview, .cloudUnavailable, .unavailable:
            "exclamationmark.triangle"
        }
    }

    private var iconColor: Color {
        switch item.availability {
        case .cachedRemote:
            connection == .available ? IOSPalette.accent : .secondary
        case .remoteOnly, .remotePending:
            IOSPalette.accent
        case .localPending, .localOnly, .accountQuarantined,
             .legacyLocal, .needsReview, .cloudUnavailable, .unavailable:
            .secondary
        }
    }

    private var statusText: String {
        IOSCloudLibraryPresentation.statusText(
            availability: item.availability,
            connection: connection
        )
    }

    private var showsChevron: Bool {
        item.availability != .cloudUnavailable && item.availability != .unavailable
    }
}

extension IOSCloudLibraryPresentation {
    static func statusText(
        availability: IOSCloudLibraryAvailability,
        connection: IOSCloudLibraryConnection
    ) -> String {
        switch availability {
        case .cachedRemote where connection == .available:
            "サーバーと同期済み"
        case .cachedRemote where connection == .offline:
            "この端末に保存済み・オフラインでも開けます"
        case .cachedRemote where connection == .checking:
            "この端末に保存済み・サーバー状態を確認中"
        case .cachedRemote where connection == .differentAccount:
            "この端末に保存済み・アカウントが異なります"
        case .cachedRemote:
            "この端末に保存済み・サーバー状態を確認できません"
        case .localPending where connection == .available:
            "この端末に保存済み・サーバーへ反映中"
        case .localPending where connection == .offline:
            "この端末に保存済み・接続後にサーバーへ同期"
        case .localPending:
            "この端末に保存済み・サーバーへは未送信"
        case .localOnly:
            "この端末にのみ保存済み"
        case .accountQuarantined where connection == .differentAccount:
            "この端末に保存済み・アカウントが異なります"
        case .accountQuarantined:
            "この端末に保存済み・サーバー設定を確認"
        case .legacyLocal:
            "タップして新しい作品として取り込む"
        case .remoteOnly where connection == .available:
            "タップしてこの端末に保存"
        case .remoteOnly where connection == .offline:
            "接続後にこの端末へダウンロード"
        case .remoteOnly:
            "サーバー状態の確認後にダウンロード"
        case .remotePending where connection == .available:
            "タップしてダウンロードを再開"
        case .remotePending where connection == .offline:
            "タップしてこの端末への保存を再開"
        case .remotePending:
            "サーバー状態の確認後にダウンロードを再開"
        case .needsReview:
            "この端末に保存済み・内容の確認が必要"
        case .cloudUnavailable:
            "サーバー上の状態を確認できません"
        case .unavailable:
            "安全に開けません"
        }
    }
}

private struct IOSLibraryRow: View {
    let item: IOSDocumentLibraryItem
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: item.availability == .available ? "book.closed" : "exclamationmark.triangle")
                .foregroundStyle(item.availability == .available ? IOSPalette.accent : Color.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(displayTitle)
                        .foregroundStyle(.primary)
                    if isCurrent {
                        Text("選択中")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                if let modificationDate = item.modificationDate {
                    Text(modificationDate, format: .dateTime.year().month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            if item.availability == .available {
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(displayTitle)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(accessibilityHint)
    }

    private var displayTitle: String {
        item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "名称未設定の作品"
            : item.title
    }

    private var detailText: String {
        switch item.availability {
        case .available:
            "\(item.chapterCount)章・\(item.episodeCount)話・\(item.characterCount)字"
        case .unreadable:
            "この作業コピーは開けません"
        }
    }

    private var accessibilityHint: String {
        switch item.availability {
        case .available:
            "作品ホームを開きます。"
        case .unreadable:
            "問題の説明を表示します。"
        }
    }

    private var accessibilityValue: String {
        var values: [String] = []
        if isCurrent {
            values.append("選択中")
        }
        values.append(detailText)
        if let modificationDate = item.modificationDate {
            values.append(
                "更新日時、\(modificationDate.formatted(date: .long, time: .shortened))"
            )
        }
        return values.joined(separator: "、")
    }
}
