import AppKit
import EditorKit
import Foundation
import NovelCore

extension AppState {
    // MARK: - スナップショット

    /// 現在の作品状態をスナップショットとして保存する。
    ///
    /// まず通常保存を完了させてから、対応リポジトリにスナップショット作成を依頼する。
    /// 非対応リポジトリの場合は `nil` を返す。本文だけでなく人物・プロット・伏線・
    /// 世界観・あらすじを含む作品全体を残す(D-074)。
    func createSnapshot(expectedSession: DocumentSessionToken? = nil) async -> URL? {
        await performForCurrentDocument(expectedSession: expectedSession, ifStale: nil) {
            await createSnapshotSerially(kind: .manual)
        }
    }

    func scheduleAutomaticSnapshotAfterEdit() {
        guard startupState.isReady, !isDocumentTransitionInProgress, !isTerminationPending else { return }
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
        cancelAutomaticSnapshotScheduling()
        await createAutomaticSnapshotIfNeeded()
    }

    @discardableResult
    func createAutomaticSnapshotIfNeeded() async -> URL? {
        await performForCurrentDocument(expectedSession: nil, ifStale: nil) {
            await createAutomaticSnapshotSerially()
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
        guard startupState.isReady, !isDocumentTransitionInProgress, !isTerminationPending else {
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
        guard repository is SnapshottingDocumentRepository else { return nil }
        guard await saveCoordinator.saveNow() else { return nil }
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
            return url
        } catch {
            print("[FUMINIWA] スナップショット保存に失敗しました(\(Self.errorCategory(error)))")
            return nil
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
            throw CancellationError()
        }
        return try await repository.saveSnapshot(document, to: packageURL)
    }

    /// 現在の作品パッケージに保存されているスナップショットを新しい順で返す。
    func listSnapshots(expectedSession: DocumentSessionToken? = nil) async -> [DocumentSnapshotInfo] {
        await performForCurrentDocument(expectedSession: expectedSession, ifStale: []) {
            await listSnapshotsSerially()
        }
    }

    private func listSnapshotsSerially() async -> [DocumentSnapshotInfo] {
        guard let repository = repository as? SnapshottingDocumentRepository else { return [] }
        let packageURL = documentURL

        do {
            return try await saveCoordinator.performExclusive {
                try await repository.listSnapshots(in: packageURL)
            }
        } catch {
            print("[FUMINIWA] スナップショット一覧の取得に失敗しました(\(Self.errorCategory(error)))")
            return []
        }
    }

    /// 指定スナップショットを現在の作品へ復元する。
    ///
    /// 復元は破壊的でないよう、現在状態を先にスナップショット化してから書き戻す。
    /// 失敗時は `documentURL` / 本文 / 資料一覧を切り替えない(docs/PHASE5.md 4.5-3a)。
    @discardableResult
    func restoreSnapshot(
        at snapshotURL: URL,
        expectedSession: DocumentSessionToken? = nil
    ) async -> Bool {
        await performForCurrentDocument(expectedSession: expectedSession, ifStale: false) {
            await restoreSnapshotSerially(at: snapshotURL)
        }
    }

    private func restoreSnapshotSerially(at snapshotURL: URL) async -> Bool {
        guard let repository = repository as? SnapshottingDocumentRepository else { return false }

        let restoredDocument: NovelDocument
        let restoredAttachments: [Attachment]
        do {
            restoredDocument = try await repository.load(from: snapshotURL)
            restoredAttachments = try await loadAttachmentsThrowing(for: snapshotURL)
        } catch {
            print("[FUMINIWA] スナップショットの読み込みに失敗しました(\(Self.errorCategory(error)))")
            return false
        }

        guard beginDocumentTransition() else { return false }
        defer { endDocumentTransition() }
        guard await flushPreparedDeviceSyncBoundarySerially(
            releaseAuthority: true,
            waitForRemote: false
        ) else { return false }

        // ここから復元結果のinstallまでは編集面を閉じる。復元中の入力が退避後に
        // 失われることを防ぎ、保存Coordinatorにも現在作品を公開しない(D-041)。
        let currentDocument = document
        let packageURL = documentURL
        startupState = .loading

        // 復元前退避と書き戻しを同じ保存排他区間で行う。通常保存が間へ入り、
        // snapshot directoryやpackage全体を別revisionで置換することを防ぐ。
        do {
            try await saveCoordinator.performExclusive {
                _ = try await repository.saveSnapshot(currentDocument, to: packageURL)
                try await repository.restoreSnapshot(from: snapshotURL, into: packageURL)
                // 待機中の通常保存が復元前モデルを同じpackageへ戻さないよう、
                // 復元結果のinstallも排他区間内で確定する。
                installDocument(restoredDocument, at: packageURL, attachments: restoredAttachments)
            }
        } catch {
            startupState = .ready
            print("[FUMINIWA] スナップショットの退避または復元に失敗しました(\(Self.errorCategory(error)))")
            return false
        }

        return true
    }
}
