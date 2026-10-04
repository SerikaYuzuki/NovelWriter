import Foundation
import NovelCore
import NovelSyncV2
@testable import NovelSyncV2Application
@testable import NovelSyncV2Runtime
@testable import NovelSyncV2Store
import NovelWorkspace
import NovelWritingStore
import NovelWritingSupport
import Testing

struct EpisodeHistoryTests {
    @Test func consecutiveBodiesCollapseButRevisitedAndMissingBodiesDoNot() {
        let key = "episode/\(UUID().uuidString.lowercased())/body"
        let firstBody = entry("firstBody", key: key), secondBody = entry("bb", key: key)
        let ids = (0 ..< 8).map { SnapshotID(data: Data("snapshot\($0)".utf8)) }
        var items = ids.enumerated().map { item($0.element, date: Double(8 - $0.offset)) }
        items[5].snapshotAvailability = .unfetched
        items[7].snapshotAvailability = .unfetched
        let result = EpisodeHistory.project(items: items, bodies: [ids[0]: firstBody, ids[1]: firstBody, ids[2]: secondBody,
                                                                   ids[3]: firstBody, ids[4]: firstBody, ids[6]: firstBody])
        let objects = result.versions.map { version in version.body.entry.objectId }
        let counts = result.versions.map { version in version.occurrences.count }
        #expect(objects == [firstBody.objectId, secondBody.objectId, firstBody.objectId, firstBody.objectId])
        #expect(counts == [2, 1, 2, 1])
        #expect(result.versions[0].previous?.entry.objectId == secondBody.objectId)
        #expect(result.versions[1].previous?.entry.objectId == firstBody.objectId)
        #expect(result.versions[2].previous == nil)
        #expect(result.unfetchedCount == 2)
    }

    @Test func collapsingAndPreviousBodySurvivePageBoundaries() {
        let key = "episode/\(UUID().uuidString.lowercased())/body"
        let firstBody = entry("A", key: key), secondBody = entry("different B", key: key)
        let ids = (0 ..< 9).map { SnapshotID(data: Data("page-snapshot\($0)".utf8)) }
        var items = ids.enumerated().map { item($0.element, date: Double(9 - $0.offset)) }
        items[7].snapshotAvailability = .unfetched
        let bodies = [ids[0]: firstBody, ids[1]: firstBody, ids[2]: firstBody, ids[3]: secondBody, ids[4]: secondBody,
                      ids[5]: secondBody, ids[6]: firstBody, ids[8]: firstBody]
        var paged = EpisodeHistory.project(items: Array(items.prefix(2)), bodies: bodies)
        let firstID = paged.versions[0].id
        paged.append(items: Array(items[2 ..< 5]), bodies: bodies)
        #expect(paged.versions[0].id == firstID)
        #expect(paged.versions[0].occurrences.count == 3)
        #expect(paged.versions[0].previous?.entry.objectId == secondBody.objectId)
        paged.append(items: Array(items[5 ..< 8]), bodies: bodies)
        paged.append(items: [items[8]], bodies: bodies)
        let whole = EpisodeHistory.project(items: items, bodies: bodies)
        let counts = paged.versions.map { version in version.occurrences.count }
        let objects = paged.versions.map { version in version.body.entry.objectId }
        let previous = paged.versions.map { version in version.previous }
        let wholePrevious = whole.versions.map { version in version.previous }
        #expect(counts == [3, 3, 1, 1])
        #expect(objects == [firstBody.objectId, secondBody.objectId, firstBody.objectId, firstBody.objectId])
        #expect(previous == wholePrevious)
        #expect(paged.unfetchedCount == 1)
    }

    @Test func historyIgnoresOtherEpisodeEditsAndCountCacheIsScoped() async throws {
        let fixture = try await LeafRuntimeFixture.make()
        var document = fixture.document
        let episode = document.chapters[0].episodes[0].id
        document.chapters[0].episodes.append(Episode(content: "other"))
        _ = try await fixture.app.checkpoint(workID: fixture.workID, document: document, reason: .explicit, documentCreatedAt: applicationTestCreatedAt)
        document.chapters[0].episodes[1].content = "other changed"
        _ = try await fixture.app.checkpoint(workID: fixture.workID, document: document, reason: .explicit, documentCreatedAt: applicationTestCreatedAt)
        let first = try await fixture.app.episodeHistory(workID: fixture.workID, episodeID: episode)
        #expect(first.versions.count == 1)
        document.chapters[0].episodes[0].content = "本文🙂が"
        _ = try await fixture.app.checkpoint(workID: fixture.workID, document: document, reason: .explicit, documentCreatedAt: applicationTestCreatedAt)
        let next = try await fixture.app.episodeHistory(workID: fixture.workID, episodeID: episode)
        #expect(next.versions.count == 2)
        let body = try #require(next.versions.first?.body)
        #expect(body.entry.objectId == SnapshotCodec.episodeBodyObjectID("本文🙂が"))
        async let one = fixture.app.episodeHistoryCharacterCount(workID: fixture.workID, body: body, episodeID: episode)
        async let two = fixture.app.episodeHistoryCharacterCount(workID: fixture.workID, body: body, episodeID: episode)
        let counts = try await [one, two]
        #expect(counts == ["本文🙂が".count, "本文🙂が".count])
        #expect(await fixture.app.episodeBodyCounts.count == 1)
        await fixture.app.invalidateEpisodeHistoryTestScope()
        #expect(await fixture.app.episodeBodyCounts.isEmpty)
        await fixture.close()
    }

    @Test @MainActor func episodeRestorePersistsAnInverseThatSurvivesReopeningTheJournal() async throws {
        let configuration = try TestRuntimeConfiguration()
        let application = try await SnapshotSyncV2Runtime.makeApplicationForTesting(mode: .test(configuration), resumeOnLaunch: false)
        let workID = WorkID(UUID())
        var document = applicationTestDocument(title: "restore", body: "current")
        document.chapters[0].episodes.append(Episode(content: "unchanged other episode"))
        let original = document
        _ = try await application.checkpoint(workID: workID, document: document, reason: .explicit,
                                             documentCreatedAt: applicationTestCreatedAt)
        let request = EpisodeRestoreRequest(scope: "restore", chapterID: document.chapters[0].id,
                                            episodeID: document.chapters[0].episodes[0].id, before: "current", after: "old")
        let host = WorkReplacementHost(scope: "restore", validate: { true }, document: { document }, boundary: { operation in
            guard await operation() else { return false }
            _ = try? await application.checkpoint(workID: workID, document: document, reason: .explicit,
                                                  documentCreatedAt: applicationTestCreatedAt)
            return true
        }, snapshot: {
            do {
                _ = try await application.checkpoint(workID: workID, document: document, reason: .explicit,
                                                     documentCreatedAt: applicationTestCreatedAt)
                return true
            } catch { return false }
        }, apply: { changes in
            for change in changes {
                document.updateEpisodeContent(change.after, for: change.episodeID, in: change.chapterID)
            }
            return true
        })
        let result = await EpisodeRestoreSession().restore(request, using: host,
                                                           journal: EpisodeRestoreJournal(application: application, workID: workID))
        #expect(result)
        #expect(document.chapters[0].episodes[1] == original.chapters[0].episodes[1])
        let context = try await application.writingContext(workID: workID)
        let records = try await application.writingRecords(context: context)
        let id = try #require(records.last.flatMap { UUID(uuidString: $0.record.key) })
        let reopened = try WritingSQLiteStore(root: configuration.localRoot.url)
        let journal = try #require(try await reopened.edit(id: id, namespace: context.workNamespace))
        #expect(journal.state == "applied")
        let edit = try JSONDecoder().decode(WritingStoredEdit.self, from: Data(journal.payload.utf8)).prepared
        #expect(try edit.inverse.applying(to: document, grant: .wholeWork) == original)
    }

    @Test func largeLocalHistoryMetadataLoad() async throws {
        let fixture = try await LeafRuntimeFixture.make()
        let episode = fixture.document.chapters[0].episodes[0].id
        try await fixture.store.seedEpisodeHistoryOccurrences(workID: fixture.workID, snapshotID: fixture.baseline, count: 10000)
        let start = ContinuousClock.now
        let bodies = try await fixture.store.episodeBodyVersions(
            workID: fixture.workID, episodeKey: "episode/\(episode.rawValue.uuidString.lowercased())/body", scope: productionScope
        )
        let sql = start.duration(to: .now)
        let timing = EpisodeHistoryReadTimings()
        let pagingStart = ContinuousClock.now
        let items = try await fixture.app.timedEpisodeHistoryItems(workID: fixture.workID, bodies: bodies, timing: timing)
        let paging = pagingStart.duration(to: .now)
        let projectStart = ContinuousClock.now
        let result = EpisodeHistory.project(items: items, bodies: bodies)
        let project = projectStart.duration(to: .now)
        #expect(result.versions.count == 1)
        #expect(result.versions[0].occurrences.count == 10001)
        #expect(await fixture.app.episodeBodyCounts.isEmpty)
        print("Episode history measured 10,001: SQL=\(sql), paging=\(paging) (local=\(timing.local), online=\(timing.online)), project=\(project), total=\(start.duration(to: .now)); body reads=0")
        let firstStart = ContinuousClock.now
        var progressive = try await fixture.app.episodeHistory(workID: fixture.workID, episodeID: episode)
        let firstPage = firstStart.duration(to: .now)
        #expect(progressive.isLoadingOlder)
        #expect(progressive.versions[0].occurrences.count == 100)
        while progressive.isLoadingOlder {
            progressive = try await fixture.app.olderEpisodeHistory(progressive)
        }
        #expect(progressive.versions.count == 1)
        #expect(progressive.versions[0].occurrences.count == 10001)
        print("Episode history incremental 10,001: first rows=\(firstPage), all pages=\(firstStart.duration(to: .now)); first page=100 occurrences, body reads=0")
        await fixture.close()
    }

    private func entry(_ text: String, key: String) -> SnapshotEntry {
        SnapshotEntry(byteCount: text.utf8.count, contentType: .entityJSON, entityKey: key, objectId: ObjectID(data: Data(text.utf8)))
    }

    private func item(_ id: SnapshotID, date: Double) -> SyncV2HistoryItem {
        SyncV2HistoryItem(occurrenceID: UUID(), snapshotID: id, reason: "autosave", pinned: false,
                          localGeneration: 1, createdAt: Date(timeIntervalSince1970: date), source: .local,
                          localAvailability: .available, onlineAvailability: .unavailable)
    }
}

private extension LocalSyncV2Store {
    func seedEpisodeHistoryOccurrences(workID: WorkID, snapshotID: SnapshotID, count: Int) throws {
        try executor.inTransaction {
            for index in 0 ..< count {
                try executor.exec("""
                INSERT INTO history_occurrences(occurrence_id,work_id,snapshot_id,reason,pinned,local_generation,created_at)
                VALUES(?,?,?,'autosave',0,1,?)
                """, [.text(UUID().uuidString.lowercased()), .text(workID.description), .blob(snapshotID.bytes),
                      .text(CanonicalTimestamp.string(Date(timeIntervalSince1970: Double(1_800_000_000 + index))))])
            }
        }
    }
}

private extension SyncV2Application {
    func invalidateEpisodeHistoryTestScope() {
        historyScopeGeneration &+= 1
    }
}

private final class EpisodeHistoryReadTimings: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Duration] = [.zero, .zero]
    var local: Duration {
        lock.withLock { values[0] }
    }

    var online: Duration {
        lock.withLock { values[1] }
    }

    func record(_ phase: HistoryReadPhase, _ duration: Duration) {
        lock.withLock { values[phase == .local ? 0 : 1] += duration }
    }
}

private extension SyncV2Application {
    func timedEpisodeHistoryItems(workID: WorkID, bodies: [SnapshotID: SnapshotEntry],
                                  timing: EpisodeHistoryReadTimings) async throws -> [SyncV2HistoryItem] {
        var items: [SyncV2HistoryItem] = []
        var cursor: String?
        let local = Set(bodies.keys)
        repeat {
            let page = try await readHistoryPage(workID: workID, cursor: cursor, pageSize: 500,
                                                 locallyAvailableSnapshots: local, timing: timing.record)
            items += page.items
            cursor = page.nextCursor
        } while cursor != nil
        return items
    }
}
