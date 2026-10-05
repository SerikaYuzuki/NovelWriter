import Foundation
import NovelSyncV2
import NovelSyncV2Application

@MainActor
public struct LibraryCoordinator {
    public let operations: LibraryOperations

    public init(operations: LibraryOperations) {
        self.operations = operations
    }

    /// Reads only SQLite. Catalog I/O is a separate deferred operation.
    public func refresh(
        account: WorkspaceAccountScope, currentAccount: () -> WorkspaceAccountScope,
        isCurrent: () -> Bool, tolerateDeletionReadFailure: Bool = false
    ) async throws -> LibraryRefresh? {
        do {
            let projection = try await operations.library()
            let pending: Set<WorkID>
            let deleted: Set<WorkID>
            if tolerateDeletionReadFailure {
                pending = await (try? operations.pendingDeletionIDs()) ?? []
                deleted = await (try? operations.deletedIDs()) ?? []
            } else {
                pending = try await operations.pendingDeletionIDs()
                deleted = try await operations.deletedIDs()
            }
            guard !Task.isCancelled, account == currentAccount(), isCurrent() else { return nil }
            return LibraryRefresh(projection: projection, pendingDeletionIDs: pending, deletedIDs: deleted)
        } catch {
            guard !Task.isCancelled, account == currentAccount(), isCurrent() else { return nil }
            throw error
        }
    }

    public enum CatalogOrder { case workID, title }

    public func catalogPage(
        cursor: String?, existingItems: [SyncV2RemoteCatalogEntry], order: CatalogOrder,
        account: WorkspaceAccountScope, currentAccount: () -> WorkspaceAccountScope,
        isCurrent: () -> Bool
    ) async throws -> SyncV2RemoteCatalogPage? {
        guard !Task.isCancelled, account == currentAccount(), isCurrent() else { return nil }
        do {
            let page = try await operations.catalog(cursor, 100)
            guard !Task.isCancelled, account == currentAccount(), isCurrent() else { return nil }
            var rows = Dictionary(uniqueKeysWithValues: existingItems.map { ($0.workID, $0) })
            for item in page.items {
                rows[item.workID] = item
            }
            let items = rows.values.sorted {
                switch order {
                case .workID: $0.workID.description < $1.workID.description
                case .title: $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
            }
            return SyncV2RemoteCatalogPage(items: items, nextCursor: page.nextCursor)
        } catch {
            guard !Task.isCancelled, account == currentAccount(), isCurrent() else { return nil }
            throw error
        }
    }

    /// Edits may advance while queued or IME commits. Work/session/account must
    /// remain installed; deletion freezes editGeneration after the local save.
    public static func matches(_ context: WorkspaceOperationContext, host: any WorkspaceHost) -> Bool {
        let current = host.operationContext
        return context.isCurrent(WorkspaceOperationContext(
            workID: current.workID, session: current.session, account: current.account,
            editGeneration: context.editGeneration == nil ? nil : current.editGeneration
        ))
    }

    public func rename(
        workID: WorkID, remoteOnly: Bool, title: String,
        context: WorkspaceOperationContext, host: any WorkspaceLibraryHost
    ) async throws -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, Self.matches(context, host: host),
              host.permitsLibraryMutation(.rename, workID: workID) else { return false }
        if remoteOnly {
            try await operations.downloadForRename(workID)
        }
        let renamed = await host.libraryMutationBoundary(.rename, workID: workID, context: context) {
            guard Self.matches(context, host: host), host.permitsLibraryLocalCompletion else { throw SyncV2ApplicationError.safeBoundaryRejected }
            try await operations.rename(workID, title)
            guard Self.matches(context, host: host), host.permitsLibraryLocalCompletion else { throw SyncV2ApplicationError.safeBoundaryRejected }
            if host.operationContext.workID == workID {
                host.document.title = title
            }
        }
        guard renamed else { return false }
        await host.refreshWorkspaceLibrary()
        return true
    }

    public func delete(
        workID: WorkID, context: WorkspaceOperationContext, host: any WorkspaceLibraryHost
    ) async throws -> Bool {
        guard Self.matches(context, host: host),
              host.permitsLibraryMutation(.deletion, workID: workID) else { return false }
        host.cancelLibraryBackgroundOperations()
        let prepared = await host.libraryMutationBoundary(.deletion, workID: workID, context: context) {
            guard Self.matches(context, host: host), host.permitsLibraryLocalCompletion else { throw SyncV2ApplicationError.safeBoundaryRejected }
            let pinned = host.operationContext
            try await operations.reserveDeletion(workID)
            guard Self.matches(pinned, host: host), host.permitsLibraryLocalCompletion else { throw SyncV2ApplicationError.safeBoundaryRejected }
            host.retireLibraryWork(workID)
        }
        guard prepared else { return false }
        if host.projectsDeletionBeforeSending {
            await host.refreshWorkspaceLibrary()
        }
        // Retirement changes session, and another work may open during HTTP.
        // Only the captured account may receive the shelf completion.
        guard host.operationContext.account == context.account,
              host.permitsLibraryDeletionSending else { return false }
        host.willSendLibraryDeletion(workID)
        do {
            try await operations.delete(workID)
        } catch {
            guard host.operationContext.account == context.account else { return false }
            throw error
        }
        guard host.operationContext.account == context.account else { return false }
        host.removeDeletedLibraryWork(workID)
        await host.refreshWorkspaceLibrary()
        return true
    }
}

public struct LibraryRefresh: Sendable {
    public let projection: SyncV2LibraryProjection
    public let pendingDeletionIDs: Set<WorkID>
    public let deletedIDs: Set<WorkID>

    public init(projection: SyncV2LibraryProjection, pendingDeletionIDs: Set<WorkID>, deletedIDs: Set<WorkID>) {
        self.projection = projection
        self.pendingDeletionIDs = pendingDeletionIDs
        self.deletedIDs = deletedIDs
    }

    public func merged(
        catalog: [SyncV2RemoteCatalogEntry], previousItems: [SyncV2LibraryItem],
        exposesAccountScopedItems: Bool = true, exposesParkedItems: Bool = true, includesQuarantinedItems: Bool = true
    ) -> [SyncV2LibraryItem] {
        let local = projection.items.filter {
            if $0.accountState == .quarantined, !includesQuarantinedItems {
                return false
            }
            if $0.accountState == .parkedDifferentAccount {
                return exposesParkedItems
            }
            return exposesAccountScopedItems || $0.accountState == .unbound
        }
        return LibraryShelf.merge(
            localItems: local, catalog: exposesAccountScopedItems ? catalog : [], previousItems: previousItems,
            pendingDeletionIDs: pendingDeletionIDs, deletedIDs: deletedIDs
        )
    }
}
