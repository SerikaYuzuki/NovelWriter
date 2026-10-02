import Foundation
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Store
import Testing

@Test(.enabled(if: ProcessInfo.processInfo.environment["FUMINIWA_IMPORT_BENCHMARK"] == "1"))
func syntheticImportPerformance() async throws {
    let root = temporaryStoreRoot("synthetic-performance")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try LocalSyncV2Store(root: root, policy: .createNew)
    let workID = WorkID(UUID())
    var document = NovelDocument(title: "Synthetic benchmark", chapters: (0 ..< 4).map {
        Chapter(title: "Episode \($0)", content: String(repeating: "a", count: 7000))
    })
    var snapshots: [EncodedSnapshot] = []
    for index in 0 ..< 1500 {
        document.chapters[0].episodes[0].content = String(repeating: "a", count: 7000) + "\(index)"
        try snapshots.append(encodeSnapshot(workID: workID, document: document,
                                            parents: snapshots.last.map { [$0.snapshotId] } ?? []))
    }
    let head = try #require(snapshots.last)
    let graph = try V2RemoteSnapshotGraph(workID: workID, headSnapshotID: head.snapshotId,
                                          snapshots: snapshots, expectedCurrentSnapshotID: nil, expectedLocalGeneration: 0,
                                          expectedRemoteHead: V2RemoteHead(snapshotID: head.snapshotId, generation: 1500))
    print("BENCH snapshots=\(snapshots.count) entries=\(head.manifest.entries.count)")
    var start = ContinuousClock.now
    try await store.stageRemoteGraph(graph, scope: scopeA)
    print("BENCH stage \(start.duration(to: .now))")
    start = .now
    try await store.verifyInbox(inboxID: graph.inboxID, scope: scopeA)
    print("BENCH verify \(start.duration(to: .now))")
    start = .now
    try await store.adoptInbox(inboxID: graph.inboxID, scope: scopeA)
    print("BENCH adopt \(start.duration(to: .now))")
    document.chapters[0].episodes[0].content += "checkpoint"
    start = .now
    _ = try await store.checkpoint(V2CheckpointRequest(workID: workID, document: document,
                                                       documentCreatedAt: testDate, expectedGeneration: 1), scope: scopeA)
    print("BENCH checkpoint \(start.duration(to: .now))")
    let initialRoot = temporaryStoreRoot("synthetic-initial-performance")
    defer { try? FileManager.default.removeItem(at: initialRoot) }
    let initial = try LocalSyncV2Store(root: initialRoot, policy: .createNew)
    start = .now
    try await initial.installInitialGraph(graph, scope: scopeA)
    _ = try await initial.open(workID: workID, scope: scopeA)
    print("BENCH full time-to-editable \(start.duration(to: .now))")
    let shallowRoot = temporaryStoreRoot("synthetic-shallow-performance")
    defer { try? FileManager.default.removeItem(at: shallowRoot) }
    let shallow = try LocalSyncV2Store(root: shallowRoot, policy: .createNew)
    let headGraph = V2RemoteSnapshotGraph(workID: workID, headSnapshotID: head.snapshotId, snapshots: [head],
                                          expectedCurrentSnapshotID: nil, expectedLocalGeneration: 0,
                                          expectedRemoteHead: graph.expectedRemoteHead)
    start = .now
    try await shallow.installShallowHead(headGraph, scope: scopeA)
    _ = try await shallow.open(workID: workID, scope: scopeA)
    print("BENCH head-first time-to-editable \(start.duration(to: .now))")
    await shallow.close()
    await initial.close()
    let contentionRoot = temporaryStoreRoot("synthetic-contention")
    defer { try? FileManager.default.removeItem(at: contentionRoot) }
    let contention = try LocalSyncV2Store(root: contentionRoot, policy: .createNew)
    let otherWork = WorkID(UUID())
    let otherDocument = makeDocument(title: "Other synthetic work")
    _ = try await contention.checkpoint(V2CheckpointRequest(workID: otherWork, document: otherDocument,
                                                            documentCreatedAt: testDate, expectedGeneration: 0), scope: scopeA)
    let probe = Task {
        var maximum = Duration.zero
        var generation: Int64 = 1
        var edited = otherDocument
        while !Task.isCancelled {
            edited.chapters[0].episodes[0].content = "probe-\(generation)"
            let began = ContinuousClock.now
            let result = try await contention.checkpoint(V2CheckpointRequest(workID: otherWork, document: edited,
                                                                             documentCreatedAt: testDate, expectedGeneration: generation), scope: scopeA)
            generation = result.generation
            maximum = max(maximum, began.duration(to: .now))
            do { try await Task.sleep(for: .milliseconds(20)) } catch { break }
        }
        return maximum
    }
    start = .now
    try await contention.installInitialGraph(graph, scope: scopeA)
    print("BENCH initial-install with concurrent checkpoint \(start.duration(to: .now))")
    probe.cancel()
    try await print("BENCH other-work checkpoint max \(probe.value)")
    await contention.close()
    await store.close()
}
