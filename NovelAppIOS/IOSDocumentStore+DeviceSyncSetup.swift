import Foundation
import NovelCore
import NovelSync

extension IOSDocumentStore {
    func refreshDeviceSyncSetupStatus(expectedSession: IOSDocumentSessionToken) async {
        guard startupState == .ready,
              currentDocumentSessionToken == expectedSession,
              let runtime = deviceSyncRuntime,
              runtime.setup != nil,
              let digest = try? SyncWorkStructureDigest(chapters: document.chapters) else { return }
        let sourceDocumentID = document.id
        deviceSyncSetupState = .loading
        do {
            let binding = try await runtime.binding(
                expectedSession.workingCopyID,
                sourceDocumentID,
                digest
            )
            guard currentDocumentSessionToken == expectedSession,
                  document.id == sourceDocumentID,
                  (try? SyncWorkStructureDigest(chapters: document.chapters)) == digest else { return }
            deviceSyncSetupState = binding == nil ? .idle : .configured
        } catch {
            guard currentDocumentSessionToken == expectedSession,
                  document.id == sourceDocumentID else { return }
            deviceSyncSetupState = .unavailable(message: "iCloud本文同期の接続状態を確認できません")
        }
    }

    func loadDeviceSyncWorkCandidates(expectedSession: IOSDocumentSessionToken) async {
        guard startupState == .ready,
              currentDocumentSessionToken == expectedSession,
              deviceSyncSetupState != .loading,
              let runtime = deviceSyncRuntime,
              let setup = deviceSyncRuntime?.setup,
              let digest = try? SyncWorkStructureDigest(chapters: document.chapters) else {
            deviceSyncSetupState = .unavailable(message: "iCloud本文同期を利用できません")
            return
        }
        let session = expectedSession
        let sourceDocumentID = document.id
        deviceSyncSetupState = .loading
        do {
            if try await runtime.binding(session.workingCopyID, sourceDocumentID, digest) != nil {
                guard currentDocumentSessionToken == session else { return }
                deviceSyncSetupState = .configured
                return
            }
            let candidates = try await setup.candidates(
                session.workingCopyID,
                sourceDocumentID,
                digest
            )
            guard currentDocumentSessionToken == session,
                  document.id == sourceDocumentID,
                  (try? SyncWorkStructureDigest(chapters: document.chapters)) == digest else { return }
            deviceSyncSetupState = .candidates(candidates)
        } catch {
            guard currentDocumentSessionToken == session else { return }
            deviceSyncSetupState = .unavailable(message: "iCloudの同期候補を確認できませんでした")
        }
    }

    @discardableResult
    func startDeviceSyncForCurrentDocument(expectedSession: IOSDocumentSessionToken) async -> Bool {
        guard currentDocumentSessionToken == expectedSession,
              deviceSyncSetupState != .loading,
              let setup = deviceSyncRuntime?.setup,
              let digest = try? SyncWorkStructureDigest(chapters: document.chapters) else { return false }
        let descriptor: SyncWorkDescriptor
        if let pending = pendingDeviceSyncNewWork,
           pending.session == expectedSession,
           pending.structureDigest == digest {
            descriptor = pending.descriptor
        } else {
            descriptor = SyncWorkDescriptor(
                workID: SyncWorkID(),
                sourceDocumentID: document.id,
                structureDigest: digest,
                title: document.title
            )
            pendingDeviceSyncNewWork = IOSPendingDeviceSyncNewWork(
                session: expectedSession,
                structureDigest: digest,
                descriptor: descriptor
            )
        }
        let succeeded = await performDeviceSyncSetupMutation(
            expectedSession: expectedSession,
            expectedDigest: digest
        ) { workingCopyID, allowedEpisodes in
            try await setup.startNew(workingCopyID, descriptor, allowedEpisodes)
        }
        if succeeded {
            pendingDeviceSyncNewWork = nil
        }
        return succeeded
    }

    @discardableResult
    func bindCurrentDocument(
        to workID: SyncWorkID,
        expectedSession: IOSDocumentSessionToken
    ) async -> Bool {
        guard currentDocumentSessionToken == expectedSession,
              deviceSyncSetupState != .loading,
              let setup = deviceSyncRuntime?.setup,
              let digest = try? SyncWorkStructureDigest(chapters: document.chapters) else { return false }
        let sourceDocumentID = document.id
        return await performDeviceSyncSetupMutation(
            expectedSession: expectedSession,
            expectedDigest: digest
        ) { workingCopyID, allowedEpisodes in
            try await setup.bindExisting(
                workingCopyID,
                sourceDocumentID,
                digest,
                workID,
                allowedEpisodes
            )
        }
    }

    private func performDeviceSyncSetupMutation(
        expectedSession: IOSDocumentSessionToken,
        expectedDigest: SyncWorkStructureDigest? = nil,
        operation: @escaping @Sendable (IOSPrivateDocumentID, [EpisodeID]) async throws -> Void
    ) async -> Bool {
        let session = expectedSession
        guard currentDocumentSessionToken == session else { return false }
        let sourceDocumentID = document.id
        let allowedEpisodes = document.chapters.flatMap(\.episodes).map(\.id)
        deviceSyncSetupState = .loading
        let succeeded = await documentOperationGate.perform { [weak self] in
            guard let self,
                  currentDocumentSessionToken == session,
                  document.id == sourceDocumentID,
                  beginDeviceSyncBoundaryTransition() else { return false }
            defer { endDeviceSyncBoundaryTransition() }
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
                      try await runtime.binding(session.workingCopyID, sourceDocumentID, digest) == nil else {
                    return false
                }
                try await operation(session.workingCopyID, allowedEpisodes)
            } catch {
                return false
            }
            guard currentDocumentSessionToken == session,
                  document.id == sourceDocumentID,
                  expectedDigest == nil ||
                  (try? SyncWorkStructureDigest(chapters: document.chapters)) == expectedDigest,
                  document.chapters.flatMap(\.episodes).map(\.id) == allowedEpisodes else { return false }
            deviceSyncSelectionDidChange()
            return true
        }
        guard currentDocumentSessionToken == session else { return false }
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
}
