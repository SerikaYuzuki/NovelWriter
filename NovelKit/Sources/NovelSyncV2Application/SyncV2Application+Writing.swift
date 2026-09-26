import Foundation
import NovelSyncV2
import NovelWritingSupport

public struct SyncV2WritingContext: Equatable, Sendable {
    public let workID: WorkID
    public let commonNamespace: String
    public let binding: SyncV2AccountScopeBinding?
    public let commonBinding: SyncV2AccountScopeBinding?
    public var workNamespace: String {
        "work:\(workID.description)"
    }

    public init(workID: WorkID, commonNamespace: String, binding: SyncV2AccountScopeBinding?, commonBinding: SyncV2AccountScopeBinding? = nil) {
        self.workID = workID; self.commonNamespace = commonNamespace; self.binding = binding; self.commonBinding = commonBinding
    }
}

public extension SyncV2LocalKernel {
    func writingContext(workID: WorkID) async throws -> SyncV2WritingContext {
        SyncV2WritingContext(workID: workID, commonNamespace: "local:common", binding: nil)
    }
}

public extension SyncV2RemoteClient {
    func appendWritingRecord(_: WritingRecord, binding _: SyncV2AccountScopeBinding) async throws -> WritingEnvelope {
        throw WritingError.unavailable
    }

    func writingRecordPage(workID _: UUID?, after _: Int64, binding _: SyncV2AccountScopeBinding) async throws -> WritingRecordPage {
        throw WritingError.unavailable
    }
}

public extension SyncV2Application {
    func copyWritingHistory(source: WorkID, destination: WorkID) async {
        guard let writingStore, let id = UUID(uuidString: destination.description) else { return }
        do {
            try await writingStore.copyHistory(source: "work:\(source.description)", destination: "work:\(destination.description)", newWorkID: id)
            writingCopyRetries[destination] = nil
        } catch {
            // The manuscript clone has already committed. Never report it as failed.
            writingCopyRetries[destination] = source
        }
    }

    func writingContext(workID: WorkID) async throws -> SyncV2WritingContext {
        try await kernel.writingContext(workID: workID)
    }

    func writingRecords(context: SyncV2WritingContext, common: Bool = false) async throws -> [WritingEnvelope] {
        try await requireWritingContext(context)
        guard let writingStore else { throw WritingError.unavailable }
        try await retryWritingHistoryCopies()
        return try await writingStore.records(namespace: common ? context.commonNamespace : context.workNamespace)
    }

    func appendWritingRecord(_ record: WritingRecord, context: SyncV2WritingContext) async throws {
        try await requireWritingContext(context)
        guard let writingStore,
              record.workId == nil || record.workId?.uuidString.lowercased() == context.workID.description else { throw WritingError.changedScope }
        try await writingStore.append(record, namespace: record.workId == nil ? context.commonNamespace : context.workNamespace)
    }

    /// Caller wakes this lane in the foreground. Never awaited by manuscript persistence.
    func synchronizeWriting(context: SyncV2WritingContext) async throws {
        try await requireWritingContext(context)
        guard let writingStore else { throw WritingError.unavailable }
        try await retryWritingHistoryCopies()
        for common in [true, false] {
            guard let binding = common ? context.commonBinding : context.binding else { continue }
            let namespace = common ? context.commonNamespace : context.workNamespace
            guard writingSyncOwners[namespace] == nil else { continue }
            let owner = UUID(); writingSyncOwners[namespace] = owner
            defer {
                if writingSyncOwners[namespace] == owner {
                    writingSyncOwners[namespace] = nil
                }
            }
            let remoteKey = "\(binding.serverInstanceID):\(binding.accountID):\(binding.accountFence)"
            // Bound each wake; foreground polling drains any backlog without stalling the app.
            for record in try await writingStore.pending(namespace: namespace) {
                try Task.checkCancellation(); try await requireWritingContext(context)
                let ack = try await remote.appendWritingRecord(record, binding: binding)
                try await requireWritingContext(context)
                guard ack.record == record else { throw WritingError.invalidRecord }
                try await writingStore.accept(ack, namespace: namespace)
            }
            var after = try await writingStore.cursor(namespace: namespace, remote: remoteKey)
            for _ in 0 ..< 32 {
                try Task.checkCancellation(); try await requireWritingContext(context)
                let page = try await remote.writingRecordPage(
                    workID: common ? nil : UUID(uuidString: context.workID.description),
                    after: after,
                    binding: binding
                )
                try await requireWritingContext(context)
                for item in page.items {
                    guard item.sequence > after,
                          item.record.workId == (common ? nil : UUID(uuidString: context.workID.description)) else { throw WritingError.invalidRecord }
                    try await writingStore.accept(item, namespace: namespace)
                    after = item.sequence
                }
                try await writingStore.advance(after, namespace: namespace, remote: remoteKey)
                guard let next = page.nextAfter else { break }
                guard next == after, !page.items.isEmpty else { throw WritingError.invalidRecord }
            }
        }
    }

    func claimWritingEdit(_ edit: WritingEdit, prepared: WritingEdit, context: SyncV2WritingContext) async throws -> Bool {
        try await requireWritingContext(context)
        guard let writingStore, edit.workId.uuidString.lowercased() == context.workID.description else { throw WritingError.changedScope }
        if try await writingEditOutcome(edit, context: context) != nil {
            return false
        }
        return try await writingStore.claimEdit(id: edit.id, namespace: context.workNamespace,
                                                payload: WritingRecord.payload(WritingStoredEdit(requested: edit, prepared: prepared)))
    }

    func writingEditOutcome(_ edit: WritingEdit, context: SyncV2WritingContext) async throws -> String? {
        guard let journal = try await writingEdit(id: edit.id, context: context) else { return nil }
        let stored = try JSONDecoder().decode(WritingStoredEdit.self, from: Data(journal.payload.utf8))
        guard stored.requested == edit else { throw WritingError.invalidEdit }
        return journal.state
    }

    private func retryWritingHistoryCopies() async throws {
        guard let writingStore else { return }
        for (destination, source) in writingCopyRetries {
            await copyWritingHistory(source: source, destination: destination)
        }
        try await writingStore.retryHistoryCopies()
    }

    func finishWritingEdit(id: UUID, state: String, context: SyncV2WritingContext) async throws {
        // Captured namespace intentionally remains valid for a journal completion after a UI switch.
        guard let writingStore else { throw WritingError.unavailable }
        try await writingStore.finishEdit(id: id, namespace: context.workNamespace, state: state)
        struct Outcome: Encodable { let state: String; let requestId: UUID; let source = "edit" }
        let record = try WritingRecord(workId: UUID(uuidString: context.workID.description), kind: "request", key: id.uuidString.lowercased(),
                                       payload: WritingRecord.payload(Outcome(state: state, requestId: id)))
        try await writingStore.append(record, namespace: context.workNamespace)
    }

    func writingEdit(id: UUID, context: SyncV2WritingContext) async throws -> WritingEditJournal? {
        try await requireWritingContext(context)
        guard let writingStore else { throw WritingError.unavailable }
        return try await writingStore.edit(id: id, namespace: context.workNamespace)
    }

    private func requireWritingContext(_ context: SyncV2WritingContext) async throws {
        guard !Task.isCancelled, activeAccountTransitionSuspensions.isEmpty,
              try await kernel.writingContext(workID: context.workID) == context else { throw WritingError.changedScope }
    }
}
