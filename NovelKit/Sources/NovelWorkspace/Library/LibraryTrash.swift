import Foundation
import NovelSyncV2
import NovelSyncV2Application

/// Display-only tombstones. SQLite manuscripts and bindings remain untouched.
public enum LibraryTrash {
    public static func confirmedDeletedIDs(
        localItems: [SyncV2LibraryItem], catalog: [SyncV2RemoteCatalogEntry], protection: [SyncV2ProtectedWork]
    ) -> Set<WorkID> {
        let present = Set(catalog.map(\.workID))
        let deleted = Set(protection.filter { !$0.localRescue && $0.deletedAt != nil }.map(\.workID))
        return Set(localItems.filter {
            $0.accountState == .active && $0.availability != .remoteOnly && !present.contains($0.workID)
                && deleted.contains($0.workID)
        }.map(\.workID))
    }

    public static func markerKey(_ account: WorkspaceAccountScope) -> String? {
        guard let id = account.accountID, let fence = account.accountFence,
              let server = account.serverInstanceID, let epoch = account.protocolEpoch else { return nil }
        let scope = [server, String(epoch), id, fence].map { Data($0.utf8).base64EncodedString() }.joined(separator: ".")
        return "fuminiwa.library.trash.\(scope)"
    }

    public static func readMarker(defaults: UserDefaults, account: WorkspaceAccountScope, removedCopies: Bool = false) -> Set<WorkID> {
        guard let base = markerKey(account) else { return [] }
        let key = base + (removedCopies ? ".removedCopies" : "")
        return Set((defaults.stringArray(forKey: key) ?? []).compactMap { try? WorkID(uuidString: $0) })
    }

    public static func writeMarker(_ ids: Set<WorkID>, defaults: UserDefaults, account: WorkspaceAccountScope, removedCopies: Bool = false) {
        guard let base = markerKey(account) else { return }
        let key = base + (removedCopies ? ".removedCopies" : "")
        defaults.set(ids.map(\.description).sorted(), forKey: key)
    }

    public static func changedCount(before: [SyncV2LibraryItem], after: [SyncV2LibraryItem]) -> Int {
        let previous = Dictionary(uniqueKeysWithValues: before.map { ($0.workID, $0.title) })
        let current = Dictionary(uniqueKeysWithValues: after.map { ($0.workID, $0.title) })
        return Set(previous.keys).union(current.keys).count(where: { previous[$0] != current[$0] })
    }
}

@MainActor
public extension LibraryCoordinator {
    /// Publish only a complete catalog; cycles or failed pages leave the previous shelf intact.
    func fullRefresh(
        account: WorkspaceAccountScope, currentAccount: () -> WorkspaceAccountScope, isCurrent: () -> Bool
    ) async throws -> (refresh: LibraryRefresh, catalog: [SyncV2RemoteCatalogEntry], protection: [SyncV2ProtectedWork]?)? {
        var items: [SyncV2RemoteCatalogEntry] = []
        var cursor: String?
        var seen: Set<String> = []
        repeat {
            guard let page = try await catalogPage(cursor: cursor, existingItems: items, order: .workID,
                                                   account: account, currentAccount: currentAccount, isCurrent: isCurrent) else { return nil }
            items = page.items
            cursor = page.nextCursor
            if let cursor, !seen.insert(cursor).inserted {
                throw SyncV2Failure.receiptMismatch
            }
        } while cursor != nil
        // Unsupported protection endpoints are unknown, never deletion evidence.
        let protection = try? await operations.protectedWorks()
        guard let local = try await refresh(account: account, currentAccount: currentAccount, isCurrent: isCurrent) else {
            return nil
        }
        return (local, items, protection)
    }

    func recover(workID: WorkID, request: SyncV2RecoveryRequest, account: WorkspaceAccountScope,
                 host: any WorkspaceLibraryHost) async throws -> Bool {
        guard host.operationContext.account == account, host.permitsLibraryDeletionSending else { return false }
        try await operations.recover(workID, request)
        guard !Task.isCancelled, host.operationContext.account == account else { return false }
        await host.refreshWorkspaceLibrary()
        return true
    }

    func rescue(workID: WorkID, context: WorkspaceOperationContext, host: any WorkspaceLibraryHost) async throws -> Bool {
        guard Self.matches(context, host: host), host.permitsLibraryMutation(.rescue, workID: workID) else { return false }
        let rescued = await host.libraryMutationBoundary(.rescue, workID: workID, context: context) {
            guard Self.matches(context, host: host), host.permitsLibraryLocalCompletion else { throw SyncV2ApplicationError.safeBoundaryRejected }
            try await operations.rescue(workID)
        }
        guard rescued, host.operationContext.account == context.account else { return false }
        await host.refreshWorkspaceLibrary()
        return true
    }
}
