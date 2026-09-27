import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Store
import Testing

@Test
func portableResourcesAreLocalOnlyAndRoundTripThroughCheckpoint() async throws {
    let root = temporaryStoreRoot("portable-resources")
    defer { try? FileManager.default.removeItem(at: root) }
    let workID = WorkID(UUID())
    let document = makeDocument(title: "resource")
    let bytes = Data("opaque".utf8)
    let resources = [
        PortableResource(pathComponents: ["snapshots"], kind: .directory),
        PortableResource(pathComponents: ["snapshots", "legacy.bin"], kind: .regularFile, bytes: bytes)
    ]
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let first = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: document,
            documentCreatedAt: testDate,
            expectedGeneration: 0,
            resources: resources
        ),
        scope: scopeA
    )
    let opened = try await store.open(workID: workID, scope: scopeA)
    #expect(opened.resources == resources)
    #expect(opened.summary.currentSnapshotID == first.snapshotID)

    let noOp = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: document,
            documentCreatedAt: testDate,
            expectedGeneration: first.generation,
            resources: resources
        ),
        scope: scopeA
    )
    #expect(noOp.noChanges)
    #expect(noOp.snapshotID == first.snapshotID)
}

@Test
func portableResourcePathCollisionFailsClosed() async throws {
    let root = temporaryStoreRoot("portable-resource-collision")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    do {
        _ = try await store.checkpoint(
            V2CheckpointRequest(
                workID: WorkID(UUID()),
                document: makeDocument(title: "collision"),
                documentCreatedAt: testDate,
                expectedGeneration: 0,
                resources: [
                    PortableResource(pathComponents: ["Notes"], kind: .directory),
                    PortableResource(pathComponents: ["notes"], kind: .directory)
                ]
            ),
            scope: scopeA
        )
        Issue.record("resource collision was accepted")
    } catch SyncV2StoreError.invalidSnapshot {
        // expected
    }
}

@Test
func ordinaryCheckpointPreservesPortableResourcesUntilExplicitClear() async throws {
    let root = temporaryStoreRoot("portable-resource-preserve")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let workID = WorkID(UUID())
    let documentID = UUID()
    let firstDocument = makeDocument(title: "first", id: documentID)
    let resources = [
        PortableResource(
            pathComponents: ["notes", "opaque.txt"],
            kind: .regularFile,
            bytes: Data("keep".utf8)
        )
    ]
    let first = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: firstDocument,
            documentCreatedAt: testDate,
            expectedGeneration: 0,
            resources: resources
        ),
        scope: scopeA
    )
    _ = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: makeDocument(title: "second", id: documentID),
            documentCreatedAt: testDate,
            expectedGeneration: first.generation
        ),
        scope: scopeA
    )
    #expect(try await store.open(workID: workID, scope: scopeA).resources == resources)
    _ = try await store.checkpoint(
        V2CheckpointRequest(
            workID: workID,
            document: makeDocument(title: "third", id: documentID),
            documentCreatedAt: testDate,
            expectedGeneration: 2,
            resources: []
        ),
        scope: scopeA
    )
    #expect(try await store.open(workID: workID, scope: scopeA).resources.isEmpty)
}

@Test
func explicitAccountCloneCopiesPortableResourceMirror() async throws {
    let root = temporaryStoreRoot("portable-resource-clone")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let source = WorkID(UUID())
    let resources = [
        PortableResource(
            pathComponents: ["opaque.bin"],
            kind: .regularFile,
            bytes: Data("shared".utf8)
        )
    ]
    _ = try await store.checkpoint(
        V2CheckpointRequest(
            workID: source,
            document: makeDocument(title: "source"),
            documentCreatedAt: testDate,
            expectedGeneration: 0,
            resources: resources
        ),
        scope: .unbound
    )
    let clone = WorkID(UUID())
    _ = try await store.prepareExplicitAccountClone(
        sourceWorkID: source,
        sourceScope: .unbound,
        newWorkID: clone,
        newDocumentID: DocumentID(UUID()),
        destination: bindingA
    )
    #expect(try await store.open(workID: clone, scope: scopeA).resources == resources)
}
