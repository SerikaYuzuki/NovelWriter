import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelWorkspace

@MainActor
final class FakeLibraryHost: WorkspaceLibraryImportHost {
    var document = NovelDocument.newDocument(title: "編集中")
    var workID: WorkID? = WorkID(UUID())
    var session: WorkspaceSessionToken?
    var account = WorkspaceAccountScope(accountID: "account", accountFence: "fence", serverInstanceID: "server",
                                        protocolEpoch: 1, generation: 0)
    var generation: UInt64 = 0
    var operationContext: WorkspaceOperationContext {
        .init(workID: workID, session: session, account: account, editGeneration: generation)
    }

    var permitsLocalMutation = true
    var permitsLibraryLocalCompletion = true
    var permitsLibraryDeletionSending = true
    var projectsDeletionBeforeSending = false
    var mutationAllowed = true
    var saveSucceeds = true
    var gateHeld = false
    var events: [String] = []
    var prepare: () async -> Void = {}
    var onRefresh: () async -> Void = {}
    var libraryOpeningWorkID: WorkID?
    var libraryImportPhases: [WorkID: ImportPhase] = [:]
    var libraryImportFailures: [WorkID: SyncV2Failure] = [:]
    var announcements: [String] = []

    init() {
        session = .init(generation: 1, documentID: document.id, workID: workID!)
    }

    func markChanged(policy _: WorkspaceSavePolicy) {}
    func applyOwnerRemoval(_ replacement: NovelDocument) {
        document = replacement
    }

    func permitsLibraryMutation(_: WorkspaceLibraryMutation, workID _: WorkID) -> Bool {
        mutationAllowed
    }

    func libraryMutationBoundary(
        _: WorkspaceLibraryMutation, workID _: WorkID, context: WorkspaceOperationContext,
        operation: @MainActor () async throws -> Void
    ) async -> Bool {
        await prepare()
        guard LibraryCoordinator.matches(context, host: self), mutationAllowed else { return false }
        gateHeld = true
        defer { gateHeld = false }
        events.append("IME/save")
        guard saveSucceeds else { return false }
        generation &+= 1 // IME can legitimately change the local editing generation.
        do { try await operation(); return true } catch { return false }
    }

    func cancelLibraryBackgroundOperations() {
        events.append("cancel-background")
    }

    func retireLibraryWork(_ deletedID: WorkID) {
        events.append("retire")
        if workID == deletedID {
            workID = nil; session = nil
        }
    }

    func refreshWorkspaceLibrary() async {
        events.append("refresh"); await onRefresh()
    }

    func removeDeletedLibraryWork(_: WorkID) {
        events.append("remove")
    }

    func willSendLibraryDeletion(_: WorkID) {
        events.append("cancel-assistant")
    }

    func announceLibraryImport(_ message: String) {
        announcements.append(message)
    }

    func invalidateAccount() {
        account = .init(accountID: account.accountID, accountFence: account.accountFence,
                        serverInstanceID: account.serverInstanceID, protocolEpoch: account.protocolEpoch,
                        generation: account.generation + 1)
    }
}

@MainActor
final class FakeLibraryOperations {
    var items: [SyncV2LibraryItem] = []
    var pending: Set<WorkID> = []
    var deleted: Set<WorkID> = []
    var phases: [WorkID: ImportPhase] = [:]
    var failures: [WorkID: SyncV2Failure] = [:]
    var events: [String] = []
    var onLibrary: () async throws -> Void = {}
    var onDownload: () async throws -> Void = {}
    var onReserve: () async throws -> Void = {}
    var onDelete: () async throws -> Void = {}
    var onPrefetch: () async throws -> Void = {}
    var onImports: () async -> Void = {}
    var onCatalog: (String?, Int) async throws -> SyncV2RemoteCatalogPage = { _, _ in .init(items: [], nextCursor: nil) }
    var operations: LibraryOperations {
        .init(
            library: { try await self.onLibrary(); self.events.append("library"); return .init(items: self.items) },
            pendingDeletionIDs: { self.pending }, deletedIDs: { self.deleted },
            catalog: { try await self.onCatalog($0, $1) },
            importStates: { await self.onImports(); return (self.phases, self.failures) },
            cancelImport: { self.events.append("cancel:\($0)") },
            downloadForRename: { _ in self.events.append("download"); try await self.onDownload() },
            prefetch: { _ in try await self.onPrefetch() },
            rename: { _, title in self.events.append("rename:\(title)") },
            reserveDeletion: { id in self.events.append("reserve"); self.pending.insert(id); try await self.onReserve() },
            delete: { id in self.events.append("delete"); try await self.onDelete(); self.pending.remove(id); self.deleted.insert(id) }
        )
    }
}
