import Foundation
@testable import FUMINIWA
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Application
import NovelSyncV2Runtime
import Testing

@Suite("macOS Snapshot Sync v2 transition races")
struct SnapshotSyncV2MacTransitionTests {
    @Test("account switch cancels automatic server adoption")
    @MainActor
    func automaticServerAdoptionCannotCrossAccountScope() async throws {
        let fixture = try await makeMacConflictFixture(remoteBehavior: .suspended)
        _ = await fixture.state.transitionFuminiwaSession(
            to: makeMacV2Session(accountID: "test-account", fence: "test-fence"),
            authState: .signedIn(accountID: "test-account")
        )
        #expect(await fixture.state.resolveSnapshotConflict(using: .useServer))
        try await waitForResolveServerOperation(fixture)

        let serverInbox = fixture.serverInbox
        await fixture.remote.setCommandHandler { sealed in
            try makeAppliedResolveServerExecution(
                operation: .command(sealed),
                inbox: serverInbox
            )
        }
        _ = await fixture.state.transitionFuminiwaSession(
            to: makeMacV2Session(accountID: "account-b", fence: "fence-b"),
            authState: .signedIn(accountID: "account-b")
        )
        await fixture.remote.resumeSuspended()
        try await waitForRetryableState(fixture)
        try? await fixture.application.resumePending()
        try await eventuallyMac(timeout: .seconds(3), stablePolls: 10) {
            let state = await fixture.application.uiState(workID: fixture.workID)
            return state?.remoteProgress == .readyForSafeAdoption(inboxID: fixture.serverInbox.inboxID)
                && fixture.state.document.title == fixture.document.title
        }

        try await eventuallyMac { fixture.state.authSession?.accountID == "account-b" }
        #expect(fixture.state.document.title == fixture.document.title)
        #expect(fixture.state.document.chapters.first?.episodes.first?.content == "本文")
        #expect(try await fixture.application.pendingAdoption(workID: fixture.workID) != nil)
    }

    @Test("account switch after Inbox apply still blocks editor installation")
    @MainActor
    func manualServerAdoptionRechecksAccountAfterSQLiteApply() async throws {
        let stateReference = MacAppStateReference()
        let newSession = makeMacV2Session(accountID: "account-b", fence: "fence-b")
        let fixture = try await makeMacConflictFixture(
            remoteBehavior: .suspended,
            afterStagedRemote: {
                _ = await stateReference.state?.transitionFuminiwaSession(
                    to: newSession,
                    authState: .signedIn(accountID: newSession.accountID)
                )
            }
        )
        stateReference.state = fixture.state
        _ = await fixture.state.transitionFuminiwaSession(
            to: makeMacV2Session(accountID: "test-account", fence: "test-fence"),
            authState: .signedIn(accountID: "test-account")
        )
        #expect(await fixture.state.resolveSnapshotConflict(using: .useServer))
        fixture.state.cancelSnapshotSyncV2BackgroundOperations()
        try await waitForResolveServerOperation(fixture)

        let serverInbox = fixture.serverInbox
        await fixture.remote.setCommandHandler { sealed in
            try makeAppliedResolveServerExecution(
                operation: .command(sealed),
                inbox: serverInbox
            )
        }
        await fixture.remote.resumeSuspended()
        try await waitForRetryableState(fixture)
        try? await fixture.application.resumePending()
        try await eventuallyMac(timeout: .seconds(3)) {
            await fixture.application.uiState(workID: fixture.workID)?.remoteProgress
                == .readyForSafeAdoption(inboxID: fixture.serverInbox.inboxID)
        }
        fixture.state.cancelSnapshotSyncV2BackgroundOperations()

        #expect(await fixture.state.applySnapshotSyncV2ServerVersion() == false)
        try await eventuallyMac { fixture.state.authSession?.accountID == "account-b" }
        #expect(fixture.state.document.title == fixture.document.title)
        #expect(fixture.state.document.chapters.first?.episodes.first?.content == "本文")
        #expect(fixture.state.snapshotSyncV2ActiveWorkID == fixture.workID)
    }

    @Test("useServerのapplied receiptは一回の選択で安全に採用する")
    @MainActor
    func serverAdoptionAppliesTheVerifiedInboxOnce() async throws {
        let fixture = try await makeMacConflictFixture(remoteBehavior: .suspended)

        #expect(await fixture.state.resolveSnapshotConflict(using: .useServer))
        try await eventuallyMac {
            let operations = await fixture.remote.recordedOperations()
            return operations.contains {
                guard case let .command(command) = $0 else { return false }
                return command.kind == .resolveServer
            }
        }

        let operations = await fixture.remote.recordedOperations()
        guard operations.contains(where: {
            guard case let .command(command) = $0 else { return false }
            return command.kind == .resolveServer
        }) else {
            Issue.record("resolveServer command was not sent")
            return
        }
        let serverInbox = fixture.serverInbox
        await fixture.remote.setCommandHandler { sealed in
            try makeAppliedResolveServerExecution(
                operation: .command(sealed),
                inbox: serverInbox
            )
        }
        await fixture.remote.resumeSuspended()
        try await eventuallyMac {
            guard let state = await fixture.application.uiState(workID: fixture.workID) else {
                return false
            }
            if case .retryable = state.remoteProgress {
                return true
            }
            return false
        }
        // Simulate a foreground/restart wake after the resolution command was
        // acknowledged. The durable adoption marker, not the conflict
        // projection, must restart the safe editor-boundary task.
        await fixture.state.resumeSnapshotSyncV2()

        try await eventuallyMac(timeout: .seconds(3)) {
            guard fixture.state.snapshotSyncV2ActiveWorkID == fixture.workID,
                  fixture.state.document.title == fixture.remoteDocument.title,
                  let state = await fixture.application.uiState(workID: fixture.workID) else {
                return false
            }
            return state.remoteProgress == .idle && state.conflict == nil
        }
        #expect(fixture.state.snapshotSyncV2ActiveWorkID == fixture.workID)
        #expect(fixture.state.document.title == fixture.remoteDocument.title)
        #expect(fixture.state.document.chapters.first?.episodes.first?.content == "サーバー本文")
        #expect(try await fixture.application.pendingAdoption(workID: fixture.workID) == nil)

        let restarted = try await SnapshotSyncV2Runtime.makeApplication(
            mode: .test(fixture.configuration)
        )
        let reopened = try await restarted.open(workID: fixture.workID)
        #expect(reopened.document?.title == fixture.remoteDocument.title)
        #expect(reopened.document?.chapters.first?.episodes.first?.content == "サーバー本文")
        let reopenedState = await restarted.uiState(workID: fixture.workID)
        #expect(reopenedState?.conflict == nil)
        #expect(try await restarted.pendingAdoption(workID: fixture.workID) == nil)
    }

    @Test("server adoption待機中に別作品へ切り替えても古いTaskはinstallしない")
    @MainActor
    func serverAdoptionDoesNotInstallAfterWorkSwitch() async throws {
        let fixture = try await makeMacConflictFixture(remoteBehavior: .suspended)
        let secondWorkID = WorkID(UUID())
        let secondDocument = NovelDocument.newDocument(title: "別作品")
        _ = try await fixture.application.checkpoint(
            workID: secondWorkID,
            document: secondDocument,
            reason: .migration,
            documentCreatedAt: Date()
        )
        let secondWork = StartupLibraryWork(
            id: secondWorkID.rawValue,
            title: secondDocument.title,
            availability: .local,
            workID: secondWorkID,
            remoteProgress: .idle
        )

        #expect(await fixture.state.resolveSnapshotConflict(using: .useServer))
        #expect(await fixture.state.openLibraryWork(secondWork))
        #expect(fixture.state.snapshotSyncV2ActiveWorkID == secondWorkID)
        #expect(fixture.state.document.title == secondDocument.title)
        try await eventuallyMac {
            let operations = await fixture.remote.recordedOperations()
            return operations.contains {
                guard case let .command(command) = $0 else { return false }
                return command.kind == .resolveServer
            }
        }

        let operations = await fixture.remote.recordedOperations()
        guard operations.contains(where: {
            guard case let .command(command) = $0 else { return false }
            return command.kind == .resolveServer
        }) else {
            Issue.record("resolveServer command was not sent")
            return
        }
        let serverInbox = fixture.serverInbox
        await fixture.remote.setCommandHandler { command in
            try makeAppliedResolveServerExecution(
                operation: .command(command),
                inbox: serverInbox
            )
        }
        await fixture.remote.resumeSuspended()
        try await eventuallyMac {
            guard let state = await fixture.application.uiState(workID: fixture.workID) else {
                return false
            }
            if case .retryable = state.remoteProgress {
                return true
            }
            return false
        }
        try? await fixture.application.resumePending()
        try await eventuallyMac(timeout: .seconds(2), stablePolls: 10) {
            guard let state = await fixture.application.uiState(workID: fixture.workID) else {
                return false
            }
            guard state.remoteProgress == .readyForSafeAdoption(inboxID: fixture.serverInbox.inboxID),
                  fixture.state.snapshotSyncV2ActiveWorkID == secondWorkID,
                  fixture.state.document.title == secondDocument.title else {
                return false
            }
            return true
        }
        #expect(fixture.state.snapshotSyncV2ActiveWorkID == secondWorkID)
        #expect(fixture.state.document.title == secondDocument.title)
        // A verified server adoption is no longer presented as a fresh choice;
        // the durable conflict remains in SQLite until the safe gate applies it.
        #expect(await fixture.application.uiState(workID: fixture.workID)?.conflict == nil)
        #expect(try await fixture.application.pendingAdoption(workID: fixture.workID) != nil)

        // Opening the non-active shelf item must project the durable adoption
        // marker and schedule the same safe gate path automatically.
        let sourceWork = StartupLibraryWork(
            id: fixture.workID.rawValue,
            title: fixture.document.title,
            availability: .cached,
            workID: fixture.workID,
            remoteProgress: .readyForSafeAdoption(inboxID: fixture.serverInbox.inboxID)
        )
        #expect(await fixture.state.openLibraryWork(sourceWork))
        try await eventuallyMac(timeout: .seconds(3)) {
            guard fixture.state.snapshotSyncV2ActiveWorkID == fixture.workID,
                  fixture.state.document.title == fixture.remoteDocument.title,
                  let state = await fixture.application.uiState(workID: fixture.workID) else {
                return false
            }
            return state.remoteProgress == .idle && state.conflict == nil
        }
        #expect(try await fixture.application.pendingAdoption(workID: fixture.workID) == nil)
    }

    @Test("restore中の別作品installはCASで拒否し現在作品を壊さない")
    @MainActor
    func restoreRejectsAnotherWorkInstalledDuringAwait() async throws {
        let fixture = try await makeMacConflictFixture(remoteBehavior: .failure(.offline))
        let originalWorkID = fixture.workID
        let originalDocument = fixture.document
        _ = try await fixture.application.checkpoint(
            workID: originalWorkID,
            document: originalDocument,
            reason: .explicit,
            documentCreatedAt: Date(timeIntervalSince1970: 1_720_000_000)
        )
        let history = try await fixture.application.historyPage(workID: originalWorkID)
        let restoreID = try #require(history.items.last?.snapshotID)
        let secondWorkID = WorkID(UUID())
        let secondDocument = NovelDocument.newDocument(title: "restore競合先")
        _ = try await fixture.application.checkpoint(
            workID: secondWorkID,
            document: secondDocument,
            reason: .migration,
            documentCreatedAt: Date()
        )

        let mutation = Task { @MainActor () -> Bool in
            for _ in 0 ..< 100 {
                if fixture.state.isDocumentTransitionInProgress {
                    fixture.state.installV2Document(
                        secondDocument,
                        workID: secondWorkID,
                        createdAt: Date()
                    )
                    fixture.state.snapshotSyncV2Session = await fixture.application.beginSession(workID: secondWorkID)
                    return true
                }
                await Task.yield()
            }
            return false
        }
        let restored = await fixture.state.restoreSnapshotV2(snapshotID: restoreID)
        #expect(await mutation.value)
        #expect(restored == false)
        #expect(fixture.state.snapshotSyncV2ActiveWorkID == secondWorkID)
        #expect(fixture.state.document.title == secondDocument.title)
    }

    @Test("restore中のaccount切替は旧accountの版をeditorへinstallしない")
    @MainActor
    func restoreRejectsAccountSwitchDuringAwait() async throws {
        let fixture = try await makeMacConflictFixture(remoteBehavior: .failure(.offline))
        let originalDocument = fixture.state.document
        let originalWorkID = try #require(fixture.state.currentSnapshotSyncV2WorkID)
        let originalSession = fixture.state.documentSessionToken
        _ = await fixture.state.transitionFuminiwaSession(
            to: makeMacV2Session(accountID: "account-a", fence: "fence-a"),
            authState: .signedIn(accountID: "account-a")
        )
        _ = try await fixture.application.checkpoint(
            workID: originalWorkID,
            document: originalDocument,
            reason: .explicit,
            documentCreatedAt: Date(timeIntervalSince1970: 1_720_000_000)
        )
        let history = try await fixture.application.historyPage(workID: originalWorkID)
        let restoreID = try #require(history.items.last?.snapshotID)

        let accountSwitch = Task { @MainActor () -> Bool in
            for _ in 0 ..< 100 {
                if fixture.state.isDocumentTransitionInProgress {
                    _ = await fixture.state.transitionFuminiwaSession(
                        to: makeMacV2Session(accountID: "account-b", fence: "fence-b"),
                        authState: .signedIn(accountID: "account-b")
                    )
                    return true
                }
                await Task.yield()
            }
            return false
        }
        let restored = await fixture.state.restoreSnapshotV2(snapshotID: restoreID)

        #expect(await accountSwitch.value)
        #expect(restored == false)
        try await eventuallyMac { fixture.state.authSession?.accountID == "account-b" }
        #expect(fixture.state.snapshotSyncV2ActiveWorkID == originalWorkID)
        #expect(fixture.state.documentSessionToken != originalSession)
        #expect(fixture.state.document == originalDocument)
    }
}

@MainActor
private final class MacAppStateReference {
    weak var state: AppState?
}

@MainActor
private func waitForResolveServerOperation(_ fixture: MacConflictFixture) async throws {
    try await eventuallyMac {
        let operations = await fixture.remote.recordedOperations()
        return operations.contains {
            guard case let .command(command) = $0 else { return false }
            return command.kind == .resolveServer
        }
    }
}

@MainActor
private func waitForRetryableState(_ fixture: MacConflictFixture) async throws {
    try await eventuallyMac {
        guard let state = await fixture.application.uiState(workID: fixture.workID) else {
            return false
        }
        if case .retryable = state.remoteProgress {
            return true
        }
        return false
    }
}

private func makeAppliedResolveServerExecution(
    operation: SyncV2RemoteOperation,
    inbox: SyncV2RemoteInbox
) throws -> SyncV2RemoteExecution {
    guard case let .command(sealed) = operation,
          sealed.kind == .resolveServer,
          let commandObject = try JSONSerialization.jsonObject(
              with: sealed.command.canonicalBytes
          ) as? [String: Any],
          let payload = commandObject["payload"] as? [String: Any],
          let workID = payload["workId"] as? String,
          let conflictID = payload["conflictId"] as? String,
          let conflictRevision = payload["conflictRevision"] as? NSNumber,
          let remoteSnapshotID = payload["remoteSnapshotId"] as? String else {
        throw SyncV2ApplicationError.invalidRuntimeMode
    }
    let readBack: [String: Any] = [
        "accountMatched": true,
        "commandDigestMatched": true,
        "headMatched": true,
        "resourceMatched": true,
        "stateMatched": true
    ]
    let receiptBody: [String: Any] = [
        "commandId": sealed.command.commandId.uuidString.lowercased(),
        "commandKind": sealed.command.commandKind,
        "readBack": readBack,
        "requestDigest": sealed.command.requestDigest.rawValue,
        "workId": workID
    ]
    let head: [String: Any] = [
        "generation": inbox.expectedRemoteHead.generation,
        "snapshotId": inbox.expectedRemoteHead.snapshotID.rawValue
    ]
    let response: [String: Any] = [
        "commandId": sealed.command.commandId.uuidString.lowercased(),
        "commandKind": sealed.command.commandKind,
        "conflictId": conflictID,
        "conflictRevision": conflictRevision,
        "head": head,
        "receipt": receiptBody,
        "remoteGeneration": inbox.expectedRemoteHead.generation,
        "remoteSnapshotId": remoteSnapshotID,
        "result": "applied"
    ]
    let responseBytes = try JSONSerialization.data(
        withJSONObject: response,
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
    let encodedResponse = responseBytes.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    let envelope: [String: Any] = [
        "canonicalResponseBase64URL": encodedResponse,
        "commandId": sealed.command.commandId.uuidString.lowercased(),
        "commandKind": sealed.command.commandKind,
        "originalResponseStatus": 200,
        "originalResult": "applied",
        "readBack": readBack,
        "requestDigest": sealed.command.requestDigest.rawValue,
        "result": "noChanges",
        "workId": workID
    ]
    let envelopeBytes = try JSONSerialization.data(
        withJSONObject: envelope,
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
    let receipt = SyncV2ReceiptReadback(
        commandID: sealed.command.commandId,
        requestDigest: sealed.command.requestDigest,
        responseStatus: 200,
        canonicalResponse: envelopeBytes,
        predicates: SyncV2ReadBackPredicates(
            accountMatched: true,
            commandDigestMatched: true,
            resourceMatched: true,
            headMatched: true,
            stateMatched: true
        ),
        result: .applied,
        verifiedInboxID: inbox.inboxID,
        remoteHead: inbox.expectedRemoteHead
    )
    return .command(receipt: receipt, remoteInbox: inbox)
}
