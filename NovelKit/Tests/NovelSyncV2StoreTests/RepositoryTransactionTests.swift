import Foundation
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Store
import Testing

@Test
func repositoryWritesShareTheStoreRollback() async throws {
    let root = temporaryStoreRoot("repository-rollback")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let workID = WorkID(UUID())
    let document = makeDocument(title: "rollback")
    let encoded = try encodeSnapshot(workID: workID, document: document)
    try await store.probeRepositoryRollback(workID: workID, document: document, encoded: encoded)
    let databaseURL = await store.databaseURL
    #expect(try await store.listWorks(scope: scopeA).isEmpty)
    #expect(try await store.pendingIntents(scope: scopeA).isEmpty)
    #expect(try sqliteScalarInt(databaseURL: databaseURL, sql: "SELECT COUNT(*) FROM snapshots") == 0)
    #expect(try sqliteScalarInt(databaseURL: databaseURL, sql: "SELECT COUNT(*) FROM objects") == 0)
    #expect(try sqliteScalarInt(databaseURL: databaseURL, sql: "SELECT COUNT(*) FROM history_occurrences") == 0)
    await store.close()
}

@Test
func nestedTransactionRejectionPreservesTheOuterTransaction() async throws {
    let root = temporaryStoreRoot("repository-nesting")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let workID = WorkID(UUID())
    try await store.probeNestedTransaction(workID: workID)
    #expect(try await store.listWorks(scope: scopeA).map(\.workID) == [workID])
    await store.close()
}

private extension LocalSyncV2Store {
    func probeRepositoryRollback(workID: WorkID, document: NovelDocument, encoded: EncodedSnapshot) throws {
        #expect(throws: SyncV2StoreError.staleCAS) {
            try inTransaction {
                try workRepository.insertWork(
                    workID: workID, documentID: DocumentID(document.id),
                    documentCreatedAt: StoreValueCoding.iso8601(testDate), lane: .normal, scope: .unbound
                )
                try accountRepository.insertBinding(workID: workID, binding: bindingA)
                try workRepository.insertEncoded(encoded, workID: workID)
                try workRepository.insertHistory(
                    workID: workID, snapshotID: encoded.snapshotId, reason: "explicit", pinned: true, generation: 1
                )
                try outboxRepository.insertIntent(.init(
                    intentID: UUID(), workID: workID, snapshotID: encoded.snapshotId,
                    generation: 1, kind: "checkpoint", scope: scopeA
                ))
                #expect(try inboxRepository.hasSnapshot(workID: workID, snapshotID: encoded.snapshotId))
                #expect(try outboxRepository.pendingIntents(scope: scopeA).count == 1)
                throw SyncV2StoreError.staleCAS
            }
        }
        #expect(executor.transactionObjects == nil)
        #expect(try !workRepository.workExists(workID: workID))
        #expect(try !accountRepository.bindingIsActive(workID: workID, binding: bindingA))
    }

    func probeNestedTransaction(workID: WorkID) throws {
        var nestedBodyRan = false
        let cachedObject = ObjectID(data: Data("transaction probe".utf8))
        try inTransaction {
            try workRepository.insertWork(
                workID: workID, documentID: DocumentID(UUID()),
                documentCreatedAt: StoreValueCoding.iso8601(testDate), lane: .normal, scope: .unbound
            )
            executor.transactionObjects?.insert(cachedObject)
            #expect(throws: SyncV2StoreError.sqlite("cannot start a transaction within a transaction")) {
                try inTransaction { nestedBodyRan = true }
            }
            #expect(!nestedBodyRan)
            #expect(executor.transactionObjects?.contains(cachedObject) == true)
            try accountRepository.insertBinding(workID: workID, binding: bindingA)
        }
        #expect(executor.transactionObjects == nil)
        #expect(try accountRepository.bindingIsActive(workID: workID, binding: bindingA))
    }
}
