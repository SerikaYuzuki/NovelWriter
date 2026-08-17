import Foundation
import NovelAuth
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Runtime

enum IOSSnapshotSyncOutcome: Equatable, Sendable {
    case notStarted, offline, idle, pending, syncing, conflict, failed
}

extension IOSDocumentStore {
    @discardableResult
    func configureSnapshotSyncV2() async -> Bool {
        if snapshotSyncV2Application != nil {
            return true
        }
        if let task = snapshotSyncV2ConfigurationTask {
            await task.value
            return snapshotSyncV2Application != nil
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { snapshotSyncV2ConfigurationTask = nil }
            do {
                let environment = FuminiwaRuntimeEnvironment(userDefaults: userDefaults)
                if environment.isTestProcess {
                    let configuration = try TestRuntimeConfiguration()
                    snapshotSyncV2Application = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
                } else if let configuration = try? ProductionRuntimeConfiguration(
                    origin: environment.syncServerURL.flatMap { try? ProductionHTTPSOrigin(url: $0) },
                    vault: makeProductionAuthVault(),
                    documentGate: snapshotSyncV2DocumentGate,
                    clientVersion: "0.1.0", clientPlatform: .ios
                ) {
                    snapshotSyncV2Application = try await SnapshotSyncV2Runtime.makeApplication(mode: .production(configuration))
                } else {
                    snapshotSyncV2Application = nil
                }
            } catch {
                snapshotSyncV2Application = nil
            }
        }
        snapshotSyncV2ConfigurationTask = task
        await task.value
        return snapshotSyncV2Application != nil
    }

    private func makeProductionAuthVault() -> (any AuthSessionVault)? {
        #if canImport(Security)
        KeychainAuthSessionVault(service: "dev.serikayuzuki.fuminiwa.sync.ios")
        #else
        nil
        #endif
    }

    @discardableResult
    func checkpointSnapshotSyncV2(
        _ value: NovelDocument,
        reason: SyncV2CheckpointReason = .autosave
    ) async -> Bool {
        guard let application = snapshotSyncV2Application else { return false }
        do {
            let result = try await application.checkpoint(
                workID: WorkID(value.id), document: value, reason: reason,
                documentCreatedAt: documentCreatedAt
            )
            snapshotSyncOutcome = result.typedResult == .noChanges ? .idle : .pending
            saveState = .saved
            return true
        } catch {
            snapshotSyncOutcome = .failed
            saveState = .failed
            return false
        }
    }

    func resumeSnapshotSyncV2() async {
        guard let application = snapshotSyncV2Application else { return }
        Task { try? await application.resumePending() }
    }

    @discardableResult
    func synchronizeSnapshotSyncV2() async -> Bool {
        guard let application = snapshotSyncV2Application else { return false }
        isSnapshotSyncInFlight = true
        defer { isSnapshotSyncInFlight = false }
        do {
            let result = try await application.synchronize(workID: WorkID(document.id))
            snapshotSyncOutcome = result.typedResult == .noChanges ? .idle : .pending
            snapshotSyncState = result.state
            snapshotSyncConflict = result.state.conflict
            return true
        } catch {
            snapshotSyncOutcome = .offline
            return false
        }
    }

    /// Adopt a verified remote resolution only after the iOS document gate,
    /// IME boundary, editor generation, and local pending intent are safe.
    @discardableResult
    func adoptPendingSnapshotSyncV2() async -> Bool {
        guard let application = snapshotSyncV2Application,
              startupState == .ready else { return false }
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  editorCommandSession.prepareForDocumentTransition(),
                  await saveNow() else { return false }
            guard let pending = try? await application.pendingAdoption(workID: WorkID(document.id)) else {
                return false
            }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            do {
                let session = await application.beginSession(workID: pending.workID)
                try await snapshotSyncV2DocumentGate.arm(
                    session: session,
                    expectedLocalVersion: pending.expectedLocalVersion,
                    proof: SyncV2SafeBoundaryProof(
                        editorGeneration: editorContentGeneration,
                        hasMarkedText: false,
                        hasUnsavedChanges: saveState != .saved,
                        pendingIntentCleared: true
                    )
                )
                let token = try await application.documentGateToken(for: session)
                let boundary = SafeAdoptionBoundary(
                    workID: pending.workID,
                    inboxID: pending.inboxID,
                    session: session,
                    gate: token
                )
                let opened = try await application.applyStagedRemote(at: boundary)
                guard let value = opened.document else { return false }
                document = value
                documentCreatedAt = opened.documentCreatedAt
                selectedChapterID = value.chapters.first?.id
                selectedEpisodeID = value.chapters.first?.episodes.first?.id
                advanceDocumentSessionGeneration()
                advanceEditorContentGeneration()
                snapshotSyncConflict = nil
                snapshotSyncOutcome = .idle
                saveState = .saved
                return true
            } catch {
                snapshotSyncOutcome = .failed
                return false
            }
        }
    }

    @discardableResult
    func openSnapshotSyncV2(workID: UUID) async -> Bool {
        guard let application = snapshotSyncV2Application else { return false }
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            do {
                let opened = try await application.open(workID: WorkID(workID))
                guard let value = opened.document else { return false }
                document = value
                documentCreatedAt = opened.documentCreatedAt
                documentURL = libraryRoot.appendingPathComponent(workID.uuidString, isDirectory: false)
                try fileManager.createDirectory(at: documentURL, withIntermediateDirectories: true)
                userDefaults.set(workID.uuidString, forKey: Self.lastDocumentNameKey)
                selectedChapterID = value.chapters.first?.id
                selectedEpisodeID = value.chapters.first?.episodes.first?.id
                advanceDocumentSessionGeneration()
                advanceEditorContentGeneration()
                startupState = .ready
                saveState = .saved
                return true
            } catch {
                operationErrorMessage = "作品を安全に開けませんでした。"
                return false
            }
        }
    }

    @discardableResult
    func restoreSnapshotSyncV2(snapshotID raw: String) async -> Bool {
        guard let app = snapshotSyncV2Application,
              let snapshotID = try? SnapshotID(rawValue: raw) else { return false }
        do {
            _ = try await app.restore(workID: WorkID(document.id), snapshotID: snapshotID)
            return true
        } catch { return false }
    }

    @discardableResult
    func resolveSnapshotSyncV2Conflict(using choice: SyncV2ConflictChoice) async -> Bool {
        guard let app = snapshotSyncV2Application,
              let conflict = snapshotSyncConflict else { return false }
        let action = SyncV2ConflictAction(
            workID: WorkID(document.id), conflictID: conflict.conflictID,
            revision: conflict.revision, baseSnapshotID: conflict.baseSnapshotID,
            localSnapshotID: conflict.localSnapshotID, remoteSnapshotID: conflict.remoteSnapshotID,
            sourceGeneration: conflict.sourceGeneration, choice: choice
        )
        do {
            let result = try await app.resolveConflict(workID: WorkID(document.id), action: action)
            snapshotSyncState = result.state
            snapshotSyncConflict = result.state.conflict
            return true
        } catch { return false }
    }
}
