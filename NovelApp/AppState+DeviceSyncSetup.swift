import Foundation
import NovelCore
import NovelSync

extension AppState {
    func refreshDeviceSyncSetupStatus(expectedSession: DocumentSessionToken) async {
        guard startupState.isReady,
              documentSessionToken == expectedSession,
              let runtime = deviceSyncRuntime,
              runtime.setup != nil,
              let digest = try? SyncWorkStructureDigest(chapters: document.chapters) else { return }
        let sourceDocumentID = document.id
        deviceSyncSetupState = .loading
        do {
            let binding = try await runtime.binding(expectedSession, digest)
            guard documentSessionToken == expectedSession,
                  document.id == sourceDocumentID,
                  (try? SyncWorkStructureDigest(chapters: document.chapters)) == digest else { return }
            deviceSyncSetupState = binding == nil ? .idle : .configured
        } catch {
            guard documentSessionToken == expectedSession,
                  document.id == sourceDocumentID else { return }
            deviceSyncSetupState = .unavailable(message: "iCloud本文同期の接続状態を確認できません")
        }
    }

    func loadDeviceSyncWorkCandidates(expectedSession: DocumentSessionToken) async {
        guard startupState.isReady,
              documentSessionToken == expectedSession,
              deviceSyncSetupState != .loading,
              let runtime = deviceSyncRuntime,
              let setup = runtime.setup else {
            deviceSyncSetupState = .unavailable(message: "iCloud本文同期を利用できません")
            return
        }
        guard let preparedSession = await ensurePrivateDeviceSyncWorkingCopy(
            expectedSession: expectedSession,
            setup: setup
        ) else { return }
        if preparedSession != expectedSession {
            await loadDeviceSyncWorkCandidates(expectedSession: preparedSession)
            return
        }
        guard
              let digest = try? SyncWorkStructureDigest(chapters: document.chapters) else {
            deviceSyncSetupState = .unavailable(message: "iCloud本文同期を利用できません")
            return
        }
        let session = expectedSession
        let sourceDocumentID = document.id
        deviceSyncSetupState = .loading
        do {
            if try await runtime.binding(session, digest) != nil {
                guard documentSessionToken == session else { return }
                deviceSyncSetupState = .configured
                return
            }
            let candidates = try await setup.candidates(session, sourceDocumentID, digest)
            guard documentSessionToken == session,
                  document.id == sourceDocumentID,
                  (try? SyncWorkStructureDigest(chapters: document.chapters)) == digest else { return }
            deviceSyncSetupState = .candidates(candidates)
        } catch {
            guard documentSessionToken == session else { return }
            deviceSyncSetupState = .unavailable(message: "iCloudの同期候補を確認できませんでした")
        }
    }

    @discardableResult
    func startDeviceSyncForCurrentDocument(expectedSession: DocumentSessionToken) async -> Bool {
        guard documentSessionToken == expectedSession,
              deviceSyncSetupState != .loading,
              let setup = deviceSyncRuntime?.setup,
              let digest = try? SyncWorkStructureDigest(chapters: document.chapters) else { return false }
        guard let preparedSession = await ensurePrivateDeviceSyncWorkingCopy(
            expectedSession: expectedSession,
            setup: setup
        ) else { return false }
        if preparedSession != expectedSession {
            return await startDeviceSyncForCurrentDocument(expectedSession: preparedSession)
        }
        let descriptor: SyncWorkDescriptor
        if let pending = pendingDeviceSyncNewWork,
           pending.session == expectedSession,
           pending.structureDigest == digest
        {
            descriptor = pending.descriptor
        } else {
            descriptor = SyncWorkDescriptor(
                workID: SyncWorkID(),
                sourceDocumentID: document.id,
                structureDigest: digest,
                title: document.title
            )
            pendingDeviceSyncNewWork = PendingDeviceSyncNewWork(
                session: expectedSession,
                structureDigest: digest,
                descriptor: descriptor
            )
        }
        let succeeded = await performDeviceSyncSetupMutation(
            expectedSession: expectedSession,
            expectedDigest: digest
        ) { session, allowedEpisodes in
            try await setup.startNew(session, descriptor, allowedEpisodes)
        }
        if succeeded {
            pendingDeviceSyncNewWork = nil
        }
        return succeeded
    }

    @discardableResult
    func bindCurrentDocument(
        to workID: SyncWorkID,
        expectedSession: DocumentSessionToken
    ) async -> Bool {
        guard documentSessionToken == expectedSession,
              deviceSyncSetupState != .loading,
              let setup = deviceSyncRuntime?.setup,
              let digest = try? SyncWorkStructureDigest(chapters: document.chapters) else { return false }
        guard let preparedSession = await ensurePrivateDeviceSyncWorkingCopy(
            expectedSession: expectedSession,
            setup: setup
        ) else { return false }
        if preparedSession != expectedSession {
            return await bindCurrentDocument(to: workID, expectedSession: preparedSession)
        }
        let sourceDocumentID = document.id
        return await performDeviceSyncSetupMutation(
            expectedSession: expectedSession,
            expectedDigest: digest
        ) { session, allowedEpisodes in
            try await setup.bindExisting(
                session,
                sourceDocumentID,
                digest,
                workID,
                allowedEpisodes
            )
        }
    }

    private func performDeviceSyncSetupMutation(
        expectedSession: DocumentSessionToken,
        expectedDigest: SyncWorkStructureDigest? = nil,
        operation: @escaping @Sendable (DocumentSessionToken, [EpisodeID]) async throws -> Void
    ) async -> Bool {
        let session = expectedSession
        guard documentSessionToken == session else { return false }
        let sourceDocumentID = document.id
        let allowedEpisodes = document.chapters.flatMap(\.episodes).map(\.id)
        deviceSyncSetupState = .loading
        let succeeded = await documentOperationGate.perform { [weak self] in
            guard let self,
                  documentSessionToken == session,
                  document.id == sourceDocumentID,
                  beginDocumentTransition() else { return false }
            defer { endDocumentTransition() }
            guard expectedDigest == nil ||
                (try? SyncWorkStructureDigest(chapters: document.chapters)) == expectedDigest,
                document.chapters.flatMap(\.episodes).map(\.id) == allowedEpisodes else { return false }
            guard await flushPreparedDeviceSyncBoundarySerially(releaseAuthority: true) else { return false }
            guard expectedDigest == nil ||
                (try? SyncWorkStructureDigest(chapters: document.chapters)) == expectedDigest,
                document.chapters.flatMap(\.episodes).map(\.id) == allowedEpisodes else { return false }
            do {
                guard let runtime = deviceSyncRuntime,
                      let digest = expectedDigest ?? (try? SyncWorkStructureDigest(chapters: document.chapters)),
                      try await runtime.binding(session, digest) == nil else { return false }
                try await operation(session, allowedEpisodes)
            } catch {
                return false
            }
            guard documentSessionToken == session,
                  document.id == sourceDocumentID,
                  expectedDigest == nil ||
                  (try? SyncWorkStructureDigest(chapters: document.chapters)) == expectedDigest,
                  document.chapters.flatMap(\.episodes).map(\.id) == allowedEpisodes else { return false }
            deviceSyncSelectionDidChange()
            return true
        }
        guard documentSessionToken == session else { return false }
        if succeeded {
            pendingDeviceSyncNewWork = nil
            deviceSyncSetupState = deviceSyncState == .unconfigured ? .idle : .configured
            if let lookup = currentDeviceSyncLookupIdentity {
                await prepareDeviceSync(for: lookup)
                deviceSyncSetupState = deviceSyncState == .unconfigured ? .idle : .configured
            }
        } else {
            deviceSyncSetupState = .unavailable(message: "本文同期の設定を完了できませんでした")
        }
        return succeeded
    }

    private func ensurePrivateDeviceSyncWorkingCopy(
        expectedSession: DocumentSessionToken,
        setup: DeviceSyncSetupRuntime
    ) async -> DocumentSessionToken? {
        guard documentSessionToken == expectedSession else { return nil }
        let destination: URL?
        do {
            destination = try setup.privateWorkingCopyDestination(expectedSession)
        } catch {
            deviceSyncSetupState = .unavailable(
                message: "同期用の端末内作業コピーを安全に確認できません"
            )
            return nil
        }
        guard let destination else { return expectedSession }
        deviceSyncSetupState = .loading
        let result = await saveDocumentResult(
            as: destination,
            expectedSession: expectedSession,
            preAdoptionValidation: setup.validatePrivateWorkingCopy
        )
        guard result == .saved,
              documentSessionToken != expectedSession else {
            deviceSyncSetupState = .unavailable(
                message: "同期用の端末内作業コピーを作成できませんでした"
            )
            return nil
        }
        let copiedSession = documentSessionToken
        do {
            // copy完了後に同じfixed root/package identityを再証明できた
            // 場合だけ新sessionを採用する。root swapはここでfail-closed。
            try setup.validatePrivateWorkingCopy(copiedSession.documentURL)
        } catch {
            // 採用直後の再検査に失敗した場合も、信頼できない
            // destinationから元packageへ書き戻さない。プロセスをfail-closedにする。
            failStartupForDeviceSyncSafety()
            return nil
        }
        deviceSyncSetupState = .idle
        return copiedSession
    }
}
