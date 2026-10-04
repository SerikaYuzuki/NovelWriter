import AppKit
import Foundation
import NovelSyncV2Application
import NovelWorkspace

/// macOSの明示Import/Exportパネルとv2履歴表示の薄いUI境界。
extension AppState {
    func presentImportPanel() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.fuminiwaNovelPackage]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = await openExternalDocument(at: url)
    }

    func presentExportPanel() async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.fuminiwaNovelPackage]
        panel.nameFieldStringValue = "\(document.title).novelpkg"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // Export is the only ordinary path allowed to call the package
            // codec. The v2 SQLite checkpoint remains the live authority.
            try await exportDocumentPackage(to: url, expectedSession: documentSessionToken)
            operationMessage = "作品を書き出しました。"
        } catch {
            operationMessage = "作品を書き出せませんでした。"
        }
    }

    func presentWholeWorkHistory() {
        NotificationCenter.default.post(name: .presentWorkHistory, object: documentSessionToken)
    }

    func refreshSnapshotHistory(publish: () -> Void = {}) async {
        guard let application = snapshotSyncV2Application else { return }
        guard let workID = currentSnapshotSyncV2WorkID else {
            snapshotSyncHistory = []
            snapshotSyncHistoryLoading = false
            snapshotSyncHistoryFailure = nil
            publish()
            return
        }
        let accountScope = snapshotSyncV2AccountScopeToken
        let documentSession = documentSessionToken
        let revision = UUID()
        snapshotSyncHistoryRevision = revision
        func isCurrent() -> Bool {
            !Task.isCancelled && snapshotSyncHistoryRevision == revision &&
                matchesSnapshotSyncV2AccountScope(accountScope) && currentSnapshotSyncV2WorkID == workID &&
                documentSessionToken == documentSession
        }
        snapshotSyncHistory = []
        snapshotSyncHistoryLoading = true
        snapshotSyncHistoryFailure = nil
        defer {
            if snapshotSyncHistoryRevision == revision {
                snapshotSyncHistoryLoading = false
            }
        }
        do {
            var page = try await application.firstHistoryPage(workID: workID)
            while true {
                guard isCurrent() else { return }
                if page.replacesItems {
                    snapshotSyncHistory = page.items
                } else {
                    snapshotSyncHistory.append(contentsOf: page.items)
                }
                snapshotSyncHistoryFailure = page.onlineFailure == nil ? nil : "オンラインの履歴を取得できません。この端末の履歴を表示しています。"
                publish()
                guard let next = page.next else { break }
                await Task.yield()
                page = try await application.olderHistoryPage(next)
            }
        } catch {
            guard isCurrent() else { return }
            snapshotSyncHistoryFailure = "履歴を読み込めませんでした。"
        }
    }

    func reportSnapshotSyncV2OpenFailure(_ error: Error) {
        snapshotSyncLibraryOpenFailure = syncV2FailureKind(error)
        logSyncV2PresentationFailure(error)
        operationMessage = remoteOnlyOpenErrorMessage(error)
    }

    func dismissOperationMessage() {
        operationMessage = nil
    }
}

extension AppState {
    func claimAutomaticAdoption(_ pending: SyncV2PendingAdoption, account: WorkspaceAccountScope) -> Bool {
        guard !pending.requiresExplicitConfirmation,
              automaticAdoptionAttempts[account]?[pending.workID]?.contains(pending.inboxID) != true else { return false }
        automaticAdoptionAttempts[account, default: [:]][pending.workID, default: []].insert(pending.inboxID)
        return true
    }
}
