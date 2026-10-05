import Foundation
import NovelSyncV2
import NovelSyncV2Application
import NovelWorkspace

extension IOSDocumentStore {
    @discardableResult
    func refreshFullLibrary() async -> Bool {
        guard !workspaceModel.libraryFullRefreshIsLoading, !isSyncV2AccountTransitionActive,
              let application = snapshotSyncV2Application else { return false }
        remoteCatalogRefreshGeneration &+= 1
        syncV2RemoteCatalogIsLoading = false
        let account = snapshotSyncV2AccountScope
        let before = workspaceModel.libraryRows
        workspaceModel.libraryFullRefreshIsLoading = true
        workspaceModel.libraryRefreshNotice = nil
        defer { workspaceModel.libraryFullRefreshIsLoading = false }
        do {
            // A background local projection may supersede this first read.
            // It must not cancel the explicit, account-scoped full refresh.
            _ = try await reloadLibraryItems()
            guard matchesSyncAccount(account) else { return false }
            guard exposesAccountScopedSyncV2Items, !isSyncV2RemoteAccountTransitionActive else {
                workspaceModel.libraryRefreshNotice = "端末の作品一覧を更新しました。サーバーの確認にはサインインが必要です。"
                return true
            }
            var operations = LibraryOperations(application: application)
            #if FUMINIWA_TEST_COMPOSITION
            if let libraryRefreshOperationsOverride {
                operations = libraryRefreshOperationsOverride(operations)
            }
            #endif
            guard let result = try await LibraryCoordinator(operations: operations).fullRefresh(
                account: account, currentAccount: { snapshotSyncV2AccountScope },
                isCurrent: { !isSyncV2RemoteAccountTransitionActive }
            ) else { return false }
            workspaceModel.remoteCatalogItems = result.catalog
            workspaceModel.remoteCatalogCursor = nil
            if let protection = result.protection {
                let ids = LibraryTrash.confirmedDeletedIDs(localItems: result.refresh.projection.items,
                                                           catalog: result.catalog, protection: protection)
                LibraryTrash.writeMarker(ids, defaults: userDefaults, account: account)
            }
            workspaceModel.pendingDeletionWorkIDs = result.refresh.pendingDeletionIDs
            deletedLibraryWorkIDs = result.refresh.deletedIDs
            libraryRefreshGeneration &+= 1
            guard applySnapshotSyncV2LibraryProjection(result.refresh.projection, expectedAccountScope: account,
                                                       refreshGeneration: libraryRefreshGeneration) else { return false }
            workspaceModel.libraryFailure = nil
            syncV2RemoteCatalogError = nil
            let count = LibraryTrash.changedCount(before: before, after: workspaceModel.libraryRows)
            workspaceModel.libraryRefreshNotice = result.protection == nil
                ? "作品一覧を更新しました。ゴミ箱の確認はできませんでした。"
                : "\(count)件の変更を反映しました"
            return true
        } catch {
            guard matchesSyncAccount(account), !Task.isCancelled else { return false }
            workspaceModel.libraryFailure = syncV2FailureKind(error)
            workspaceModel.libraryRefreshNotice = "サーバーの作品一覧を更新できませんでした。接続後に再試行してください。"
            return false
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
        let account = snapshotSyncV2AccountScope
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
