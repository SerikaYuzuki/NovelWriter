import Foundation
import NovelSyncV2
import NovelSyncV2Application
import NovelWorkspace

extension AppState {
    /// Explicit menu/toolbar action; it also works while the editor is open.
    func refreshFullLibrary() async {
        guard !workspaceModel.libraryFullRefreshIsLoading, let application = snapshotSyncV2Application else { return }
        snapshotSyncV2CatalogRefreshToken = nil
        workspaceModel.libraryIsLoading = false
        let account = snapshotSyncV2AccountScopeToken
        let before = workspaceModel.libraryRows
        workspaceModel.libraryFullRefreshIsLoading = true
        workspaceModel.libraryRefreshNotice = nil
        defer { workspaceModel.libraryFullRefreshIsLoading = false }
        await refreshSnapshotLibrary()
        guard matchesSnapshotSyncV2AccountScope(account) else { return }
        guard case .signedIn = workspaceModel.authUIState else {
            workspaceModel.libraryRefreshNotice = "端末の作品一覧を更新しました。サーバーの確認にはサインインが必要です。"
            return
        }
        var operations = LibraryOperations(application: application)
        #if FUMINIWA_TEST_COMPOSITION
        if let snapshotSyncV2CatalogOverride {
            operations.catalog = { try await snapshotSyncV2CatalogOverride(application, $0, $1) }
        }
        if let snapshotSyncV2LibraryOverride {
            operations.library = { try await snapshotSyncV2LibraryOverride(application) }
        }
        if let libraryRefreshOperationsOverride {
            operations = libraryRefreshOperationsOverride(operations)
        }
        #endif
        do {
            guard let result = try await LibraryCoordinator(operations: operations).fullRefresh(
                account: account, currentAccount: { snapshotSyncV2AccountScopeToken }, isCurrent: { true }
            ) else { return }
            workspaceModel.remoteCatalogItems = result.catalog
            workspaceModel.remoteCatalogCursor = nil
            if let protection = result.protection {
                let ids = LibraryTrash.confirmedDeletedIDs(localItems: result.refresh.projection.items,
                                                           catalog: result.catalog, protection: protection)
                LibraryTrash.writeMarker(ids, defaults: userDefaults, account: account)
            }
            await refreshSnapshotLibrary()
            guard matchesSnapshotSyncV2AccountScope(account) else { return }
            let count = LibraryTrash.changedCount(before: before, after: workspaceModel.libraryRows)
            workspaceModel.libraryRefreshNotice = result.protection == nil
                ? "作品一覧を更新しました。ゴミ箱の確認はできませんでした。"
                : "\(count)件の変更を反映しました"
        } catch {
            guard matchesSnapshotSyncV2AccountScope(account), !Task.isCancelled else { return }
            workspaceModel.libraryFailure = syncV2FailureKind(error)
            workspaceModel.libraryRefreshNotice = "サーバーの作品一覧を更新できませんでした。接続後に再試行してください。"
        }
    }

    func restoreTrashWork(_ workID: WorkID, request: SyncV2RecoveryRequest) async -> Bool {
        guard let application = snapshotSyncV2Application else { return false }
        var operations = LibraryOperations(application: application)
        #if FUMINIWA_TEST_COMPOSITION
        if let libraryRefreshOperationsOverride {
            operations = libraryRefreshOperationsOverride(operations)
        }
        #endif
        return await (try? LibraryCoordinator(operations: operations).recover(
            workID: workID, request: request, account: operationContext.account, host: self
        )) ?? false
    }

    func rescueTrashWork(_ workID: WorkID) async -> Bool {
        guard let application = snapshotSyncV2Application else { return false }
        var operations = LibraryOperations(application: application)
        #if FUMINIWA_TEST_COMPOSITION
        if let libraryRefreshOperationsOverride {
            operations = libraryRefreshOperationsOverride(operations)
        }
        #endif
        return await (try? LibraryCoordinator(operations: operations).rescue(
            workID: workID, context: WorkspaceOperationContext(workID: operationContext.workID, session: operationContext.session,
                                                               account: operationContext.account, editGeneration: nil), host: self
        )) ?? false
    }

    func deleteTrashWork(_ workID: WorkID) async -> Bool {
        guard let application = snapshotSyncV2Application else { return false }
        var operations = LibraryOperations(application: application)
        #if FUMINIWA_TEST_COMPOSITION
        if let libraryRefreshOperationsOverride {
            operations = libraryRefreshOperationsOverride(operations)
        }
        #endif
        let account = snapshotSyncV2AccountScopeToken
        let deleted = await (try? LibraryCoordinator(operations: operations).delete(
            workID: workID, context: WorkspaceOperationContext(workID: operationContext.workID, session: operationContext.session,
                                                               account: operationContext.account, editGeneration: nil), host: self
        )) ?? false
        if deleted, operationContext.account == account {
            var ids = LibraryTrash.readMarker(defaults: userDefaults, account: account, removedCopies: true)
            ids.insert(workID)
            LibraryTrash.writeMarker(ids, defaults: userDefaults, account: account, removedCopies: true)
            workspaceModel.removedTrashCopyIDs = ids
            workspaceModel.trashLocalItems.removeAll { $0.workID == workID }
        }
        return deleted
    }
}
