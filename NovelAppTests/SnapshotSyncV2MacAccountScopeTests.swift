import Foundation
@testable import FUMINIWA
import NovelAuth
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Runtime
import Testing

@Suite("macOS Snapshot Sync v2 account scope races")
struct SnapshotSyncV2MacAccountScopeTests {
    @Test("old account catalog completion cannot repopulate the new account shelf")
    @MainActor
    func catalogCompletionIsRejectedAfterAccountSwitch() async throws {
        let suspendedCatalog = SuspendedMacCatalog()
        var dependencies = try makeAccountScopeDependencies()
        dependencies.snapshotSyncV2CatalogOverride = { _, cursor, _ in
            await suspendedCatalog.page(cursor: cursor)
        }
        let state = AppState(dependencies: dependencies)
        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()
        state.transitionFuminiwaSession(
            to: makeMacV2Session(accountID: "account-a", fence: "fence-a"),
            authState: .signedIn(accountID: "account-a")
        )

        let refresh = Task { @MainActor in
            await state.refreshSnapshotRemoteCatalog()
        }
        try await eventuallyMac {
            await suspendedCatalog.isWaiting
        }

        state.transitionFuminiwaSession(
            to: makeMacV2Session(accountID: "account-b", fence: "fence-b"),
            authState: .signedIn(accountID: "account-b")
        )
        let staleWorkID = WorkID(UUID())
        await suspendedCatalog.resume(
            with: SyncV2RemoteCatalogPage(
                items: [
                    SyncV2RemoteCatalogEntry(
                        workID: staleWorkID,
                        title: "旧アカウント作品",
                        head: nil
                    )
                ],
                nextCursor: nil
            )
        )
        await refresh.value

        #expect(state.authSession?.accountID == "account-b")
        #expect(state.snapshotSyncRemoteCatalogItems.isEmpty)
        #expect(state.snapshotSyncLibraryWorks.allSatisfy { $0.workID != staleWorkID })
    }

    @Test("old account remote-only download cannot install into the editor")
    @MainActor
    func remoteOnlyCompletionIsRejectedAfterAccountSwitch() async throws {
        let suspendedOpen = SuspendedMacAccountOpen()
        var dependencies = try makeAccountScopeDependencies()
        dependencies.snapshotSyncV2OpenOverride = { _, workID in
            await suspendedOpen.open(workID: workID)
        }
        let state = AppState(dependencies: dependencies)
        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()
        state.transitionFuminiwaSession(
            to: makeMacV2Session(accountID: "account-a", fence: "fence-a"),
            authState: .signedIn(accountID: "account-a")
        )
        let originalWorkID = try #require(state.snapshotSyncV2ActiveWorkID)
        let originalSession = state.documentSessionToken
        let originalDocument = state.document
        let remoteWorkID = WorkID(UUID())
        let remoteWork = StartupLibraryWork(
            id: remoteWorkID.rawValue,
            title: "旧アカウントの取得作品",
            availability: .remoteOnly,
            workID: remoteWorkID,
            remoteProgress: .idle
        )
        state.snapshotSyncLibraryWorks = [remoteWork]

        #expect(await state.openLibraryWork(remoteWork))
        try await eventuallyMac {
            await suspendedOpen.isWaiting(for: remoteWorkID)
        }
        state.transitionFuminiwaSession(
            to: makeMacV2Session(accountID: "account-b", fence: "fence-b"),
            authState: .signedIn(accountID: "account-b")
        )
        await suspendedOpen.resume(
            returning: SyncV2OpenedWork(
                workID: remoteWorkID,
                document: NovelDocument.newDocument(title: "届いてはいけない作品"),
                documentCreatedAt: Date(),
                generation: 1,
                snapshotID: nil
            )
        )
        try await eventuallyMac {
            state.snapshotSyncV2RemoteOnlyOpenTask == nil
        }

        #expect(state.authSession?.accountID == "account-b")
        #expect(state.snapshotSyncV2ActiveWorkID == originalWorkID)
        #expect(state.documentSessionToken == originalSession)
        #expect(state.document == originalDocument)
        #expect(state.operationMessage == nil)
    }

    @Test("old account local shelf open cannot install into the editor")
    @MainActor
    func localOpenCompletionIsRejectedAfterAccountSwitch() async throws {
        let suspendedOpen = SuspendedMacAccountOpen()
        var dependencies = try makeAccountScopeDependencies()
        dependencies.snapshotSyncV2OpenLocalOverride = { _, workID in
            await suspendedOpen.open(workID: workID)
        }
        let state = AppState(dependencies: dependencies)
        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()
        state.transitionFuminiwaSession(
            to: makeMacV2Session(accountID: "account-a", fence: "fence-a"),
            authState: .signedIn(accountID: "account-a")
        )
        let originalWorkID = try #require(state.snapshotSyncV2ActiveWorkID)
        let originalSession = state.documentSessionToken
        let originalDocument = state.document
        let localWorkID = WorkID(UUID())
        let localWork = StartupLibraryWork(
            id: localWorkID.rawValue,
            title: "旧アカウントの端末作品",
            availability: .local,
            workID: localWorkID,
            remoteProgress: .idle
        )

        let opening = Task { @MainActor in
            await state.openLibraryWork(localWork)
        }
        try await eventuallyMac {
            await suspendedOpen.isWaiting(for: localWorkID)
        }
        state.transitionFuminiwaSession(
            to: makeMacV2Session(accountID: "account-b", fence: "fence-b"),
            authState: .signedIn(accountID: "account-b")
        )
        await suspendedOpen.resume(
            returning: SyncV2OpenedWork(
                workID: localWorkID,
                document: NovelDocument.newDocument(title: "届いてはいけない端末作品"),
                documentCreatedAt: Date(),
                generation: 1,
                snapshotID: nil
            )
        )

        #expect(await opening.value == false)
        #expect(state.authSession?.accountID == "account-b")
        #expect(state.snapshotSyncV2ActiveWorkID == originalWorkID)
        #expect(state.documentSessionToken == originalSession)
        #expect(state.document == originalDocument)
        #expect(state.operationMessage == nil)
    }
}

@MainActor
func makeMacV2Session(accountID: String, fence: String) -> FuminiwaSession {
    let now = Date()
    return FuminiwaSession(
        binding: AuthSessionBinding(
            serverInstanceID: UUID(),
            syncProtocolEpoch: 2,
            accountID: accountID,
            accountAuthEpoch: 1,
            accountFence: fence,
            sessionID: UUID()
        ),
        tokens: AuthSessionTokens(
            accessToken: "test-access-\(accountID)",
            accessTokenExpiresAt: now.addingTimeInterval(3600),
            refreshToken: "test-refresh-\(accountID)",
            refreshTokenExpiresAt: now.addingTimeInterval(86400),
            refreshGeneration: 1
        ),
        receipt: AuthReceipt(
            commandKind: "appleExchange",
            operationID: UUID(),
            replayUntil: now.addingTimeInterval(300)
        )
    )
}

@MainActor
private func makeAccountScopeDependencies() throws -> AppDependencies {
    let configuration = try TestRuntimeConfiguration()
    let defaults = try #require(
        UserDefaults(suiteName: "FUMINIWA.SnapshotSyncV2MacAccountScopeTests.\(UUID().uuidString)")
    )
    return AppDependencies(
        userDefaults: defaults,
        snapshotSyncV2Factory: {
            try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        }
    )
}

private actor SuspendedMacCatalog {
    private var continuation: CheckedContinuation<SyncV2RemoteCatalogPage, Never>?

    var isWaiting: Bool {
        continuation != nil
    }

    func page(cursor _: String?) async -> SyncV2RemoteCatalogPage {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume(with page: SyncV2RemoteCatalogPage) {
        let waiting = continuation
        continuation = nil
        waiting?.resume(returning: page)
    }
}

private actor SuspendedMacAccountOpen {
    private var waitingWorkID: WorkID?
    private var continuation: CheckedContinuation<SyncV2OpenedWork, Never>?

    func open(workID: WorkID) async -> SyncV2OpenedWork {
        waitingWorkID = workID
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func isWaiting(for workID: WorkID) -> Bool {
        waitingWorkID == workID && continuation != nil
    }

    func resume(returning opened: SyncV2OpenedWork) {
        waitingWorkID = nil
        let waiting = continuation
        continuation = nil
        waiting?.resume(returning: opened)
    }
}
