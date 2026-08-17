import AppKit
import Foundation
import NovelSyncV2Application

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

    func refreshSnapshotHistory() async {
        guard let application = snapshotSyncV2Application else { return }
        guard let workID = currentSnapshotSyncV2WorkID else {
            snapshotSyncHistory = []
            return
        }
        let accountScope = snapshotSyncV2AccountScopeToken
        let documentSession = documentSessionToken
        do {
            var cursor: String?
            var items: [SyncV2HistoryItem] = []
            repeat {
                guard matchesSnapshotSyncV2AccountScope(accountScope),
                      currentSnapshotSyncV2WorkID == workID,
                      documentSessionToken == documentSession else { return }
                let page = try await application.historyPage(
                    workID: workID,
                    cursor: cursor,
                    pageSize: 100
                )
                items.append(contentsOf: page.items)
                cursor = page.nextCursor
            } while cursor != nil
            guard matchesSnapshotSyncV2AccountScope(accountScope),
                  currentSnapshotSyncV2WorkID == workID,
                  documentSessionToken == documentSession else {
                return
            }
            snapshotSyncHistory = items
        } catch {
            snapshotSyncHistory = []
        }
    }

    func dismissOperationMessage() {
        operationMessage = nil
    }
}
