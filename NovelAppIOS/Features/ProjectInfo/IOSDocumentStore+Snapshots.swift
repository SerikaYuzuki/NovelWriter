import Foundation
import NovelCore
import NovelStorage

extension IOSDocumentStore {
    func scheduleAutomaticSnapshotAfterEdit() {
        guard startupState == .ready, !isDocumentTransitionInProgress else { return }
        if let automaticSnapshotTask, !automaticSnapshotTask.isCancelled {
            return
        }
        automaticSnapshotTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: DocumentSnapshotPolicy.automaticDelayNanoseconds)
            while !Task.isCancelled {
                guard let self else { return }
                if case .compositionInProgress = editorCommandSession.captureActiveCommittedText() {
                    try? await Task.sleep(
                        nanoseconds: DocumentSnapshotPolicy.automaticCompositionRetryNanoseconds
                    )
                    continue
                }
                await createAutomaticSnapshotIfNeeded()
                return
            }
        }
    }

    func captureAutomaticSnapshotForBackground() async {
        automaticSnapshotTask?.cancel()
        automaticSnapshotTask = nil
        await createAutomaticSnapshotIfNeeded()
    }

    func createSnapshot(expectedSession: IOSDocumentSessionToken) async -> URL? {
        await documentOperationGate.perform { [weak self] in
            guard let self, validateCurrentDocumentSession(expectedSession) else {
                print("[FUMINIWA] snapshot save skipped(stale-session)")
                return nil
            }
            return await createSnapshotSerially(kind: .manual)
        }
    }

    @discardableResult
    func createAutomaticSnapshotIfNeeded() async -> URL? {
        await documentOperationGate.perform { [weak self] in
            guard let self else { return nil }
            return await createAutomaticSnapshotSerially()
        }
    }

    func listSnapshots(expectedSession: IOSDocumentSessionToken) async -> [DocumentSnapshotInfo] {
        await documentOperationGate.perform { [weak self] in
            guard let self, matchesCurrentDocumentSession(expectedSession) else { return [] }
            return await listSnapshotsSerially()
        }
    }

    @discardableResult
    func restoreSnapshot(
        at snapshotURL: URL,
        expectedSession: IOSDocumentSessionToken
    ) async -> Bool {
        await documentOperationGate.perform { [weak self] in
            guard let self, validateCurrentDocumentSession(expectedSession) else { return false }
            return await restoreSnapshotSerially(at: snapshotURL)
        }
    }

    func cancelAutomaticSnapshotScheduling() {
        automaticSnapshotTask?.cancel()
        automaticSnapshotTask = nil
    }

    private func scheduleAutomaticSnapshotCompositionRetry() {
        guard automaticSnapshotTask == nil || automaticSnapshotTask?.isCancelled == true else { return }
        automaticSnapshotTask = Task { [weak self] in
            try? await Task.sleep(
                nanoseconds: DocumentSnapshotPolicy.automaticCompositionRetryNanoseconds
            )
            guard !Task.isCancelled else { return }
            await self?.createAutomaticSnapshotIfNeeded()
        }
    }

    private func createAutomaticSnapshotSerially() async -> URL? {
        automaticSnapshotTask = nil
        guard startupState == .ready, !isDocumentTransitionInProgress else {
            print("[FUMINIWA] snapshot auto skipped(not-ready)")
            return nil
        }
        if case .compositionInProgress = editorCommandSession.captureActiveCommittedText() {
            print("[FUMINIWA] snapshot auto skipped(ime)")
            scheduleAutomaticSnapshotCompositionRetry()
            return nil
        }
        guard await saveCoordinator.saveNow() else {
            print("[FUMINIWA] snapshot auto skipped(local-save-failed)")
            return nil
        }
        guard saveCoordinator.lastSavedRevision > lastAutomaticSnapshotRevision else {
            print("[FUMINIWA] snapshot auto skipped(unchanged)")
            return nil
        }
        return await createSnapshotSerially(kind: .automatic)
    }

    private func createSnapshotSerially(kind: DocumentSnapshotKind) async -> URL? {
        guard startupState == .ready else {
            print("[FUMINIWA] snapshot save skipped(not-ready)")
            return nil
        }
        guard repository is SnapshottingDocumentRepository else {
            print("[FUMINIWA] snapshot save skipped(not-snapshotting)")
            return nil
        }
        print("[FUMINIWA] snapshot save begin")
        guard await saveCoordinator.saveNow() else {
            print("[FUMINIWA] snapshot save skipped(local-save-failed)")
            if kind == .manual {
                operationErrorMessage = "スナップショットを保存できませんでした。この端末の作品はそのまま残っています。"
            }
            return nil
        }
        let documentSnapshot = document
        let packageURL = documentURL

        do {
            let url = try await saveCoordinator.performExclusive {
                try await saveSnapshotOnRepository(
                    documentSnapshot,
                    to: packageURL,
                    kind: kind
                )
            }
            lastAutomaticSnapshotRevision = saveCoordinator.lastSavedRevision
            if kind == .manual {
                cancelAutomaticSnapshotScheduling()
            }
            print("[FUMINIWA] snapshot save ok")
            return url
        } catch {
            print("[FUMINIWA] snapshot save failed(\(String(reflecting: type(of: error))))")
            if kind == .manual {
                operationErrorMessage = "スナップショットを保存できませんでした。この端末の作品はそのまま残っています。"
            }
            return nil
        }
    }

    private func listSnapshotsSerially() async -> [DocumentSnapshotInfo] {
        guard startupState == .ready,
              let repository = repository as? SnapshottingDocumentRepository else { return [] }
        let packageURL = documentURL

        do {
            return try await saveCoordinator.performExclusive {
                try await repository.listSnapshots(in: packageURL)
            }
        } catch {
            print("[FUMINIWA] snapshot list failed(\(String(reflecting: type(of: error))))")
            return []
        }
    }

    private func restoreSnapshotSerially(at snapshotURL: URL) async -> Bool {
        guard startupState == .ready,
              let repository = repository as? SnapshottingDocumentRepository else { return false }

        let restoredDocument: NovelDocument
        let restoredAttachments: [Attachment]
        do {
            restoredDocument = try await repository.load(from: snapshotURL)
            restoredAttachments = try await loadAttachmentsForInstall(at: snapshotURL)
        } catch {
            print("[FUMINIWA] snapshot load failed(\(String(reflecting: type(of: error))))")
            operationErrorMessage = "スナップショットを読み込めませんでした。現在の作品は変更していません。"
            return false
        }

        guard !isDocumentTransitionInProgress else { return false }
        isDocumentTransitionInProgress = true
        operationErrorMessage = nil
        guard editorCommandSession.prepareForDocumentTransition() else {
            operationErrorMessage = "日本語入力を確定できませんでした。変換を確定してから、もう一度お試しください。"
            isDocumentTransitionInProgress = false
            return false
        }
        defer {
            editorCommandSession.resumeAfterDocumentTransition()
            isDocumentTransitionInProgress = false
        }

        guard await flushPreparedDeviceSyncBoundarySerially(
            releaseAuthority: true,
            waitForRemote: false
        ) else {
            operationErrorMessage = "現在の作品を保存できなかったため、スナップショットの復元を中止しました。"
            return false
        }

        do {
            let currentDocument = document
            let packageURL = documentURL
            try await saveCoordinator.performExclusive {
                _ = try await saveSnapshotOnRepository(
                    currentDocument,
                    to: packageURL,
                    kind: .manual
                )
                try await repository.restoreSnapshot(from: snapshotURL, into: packageURL)
                guard install(
                    restoredDocument,
                    at: packageURL,
                    attachments: restoredAttachments
                ) else {
                    throw IOSPrivateWorkingCopyLocationError.unsafeRoot
                }
            }
            lastAutomaticSnapshotRevision = saveCoordinator.lastSavedRevision
            return true
        } catch {
            print("[FUMINIWA] snapshot restore failed(\(String(reflecting: type(of: error))))")
            operationErrorMessage = "スナップショットを復元できませんでした。保存に失敗したか、ファイルにアクセスできない可能性があります。"
            return false
        }
    }

    private func saveSnapshotOnRepository(
        _ document: NovelDocument,
        to packageURL: URL,
        kind: DocumentSnapshotKind
    ) async throws -> URL {
        if let repository = repository as? any AutomaticSnapshottingDocumentRepository {
            return try await repository.saveSnapshot(document, to: packageURL, kind: kind)
        }
        guard let repository = repository as? SnapshottingDocumentRepository else {
            throw IOSPrivateWorkingCopyLocationError.unsafeRoot
        }
        return try await repository.saveSnapshot(document, to: packageURL)
    }
}
