#if os(macOS)
@testable import FUMINIWA
#else
@testable import FUMINIWAIOS
#endif
import CSQLite
import Foundation
import NovelCore
import NovelTextAnalysis
import Testing

/// Timeout bounds a broken test; successful assertions wait for state, never a fixed delay.
@MainActor
func waitForWorkSearchState(_ predicate: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while !predicate() {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw WorkSearchStateTimeout.notCompleted }
        await Task.yield()
    }
}

private enum WorkSearchStateTimeout: Error { case notCompleted }

@MainActor
private final class WorkSearchTestClock {
    var delays: [Duration] = []
    private var sleepers: [(UUID, CheckedContinuation<Void, Error>)] = []
    private var waiter: CheckedContinuation<Duration, Never>?

    func sleep(_ delay: Duration) async throws {
        try Task.checkCancellation()
        let id = UUID()
        delays.append(delay)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    sleepers.append((id, continuation))
                    waiter?.resume(returning: delay); waiter = nil
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = sleepers.firstIndex(where: { $0.0 == id }) else { return }
        sleepers.remove(at: index).1.resume(throwing: CancellationError())
    }

    func scheduled(_ index: Int) async -> Duration {
        if delays.count > index {
            return delays[index]
        }
        return await withCheckedContinuation { waiter = $0 }
    }

    func advance() {
        sleepers.removeFirst().1.resume()
    }
}

@MainActor
struct WorkSearchSessionTests {
    @Test func hiddenChangesRetainResultsAndReappearComputesOnce() async throws {
        let fixture = ReplacementFixture(), searches = SearchComputationCounter(), detections = SearchComputationCounter()
        let searchClock = WorkSearchTestClock(), appearanceClock = WorkSearchTestClock()
        let search = WorkSearchSession(search: { query, document in
            searches.increment()
            return WorkTextSearch.search(query: query, in: document)
        }, sleep: searchClock.sleep)
        let appearance = CharacterAppearanceSession(detect: { character, document in
            detections.increment()
            return CharacterAppearanceDetector.appearances(for: character, in: document)
        }, sleep: appearanceClock.sleep)
        let character = NovelCore.Character(name: "猫")
        search.query = "猫"
        search.setVisible(true, document: fixture.document, scope: "test")
        appearance.setVisible(true, character: character, document: fixture.document)
        #expect(await searchClock.scheduled(0) == .milliseconds(250))
        #expect(await appearanceClock.scheduled(0) == .milliseconds(250))
        searchClock.advance(); appearanceClock.advance()
        try await waitForWorkSearchState { !search.isStale && !appearance.isStale }
        let oldTotal = search.total, oldAppearances = appearance.appearances
        #expect(searches.value == 1)
        #expect(detections.value == 1)
        search.setVisible(false, document: fixture.document, scope: "test")
        appearance.setVisible(false, character: character, document: fixture.document)
        for _ in 0 ..< 5 {
            fixture.document.chapters[0].episodes[0].content += "猫"
            search.markStale()
            // Query changes and character changes use refresh, which must respect visibility too.
            search.refresh(document: fixture.document, scope: "test")
            appearance.refresh(character: character, document: fixture.document)
        }
        #expect(searches.value == 1)
        #expect(detections.value == 1)
        #expect(search.total == oldTotal)
        #expect(appearance.appearances.map(\.source) == oldAppearances.map(\.source))
        #expect(search.isStale)
        #expect(!search.isSearching)
        #expect(!appearance.isLoading)
        #expect(searchClock.delays.count == 1)
        #expect(appearanceClock.delays.count == 1)
        search.setVisible(true, document: fixture.document, scope: "test")
        appearance.setVisible(true, character: character, document: fixture.document)
        #expect(await searchClock.scheduled(1) == .milliseconds(250))
        #expect(await appearanceClock.scheduled(1) == .milliseconds(250))
        searchClock.advance(); appearanceClock.advance()
        try await waitForWorkSearchState { !search.isStale && !appearance.isStale }
        #expect(searches.value == 2)
        #expect(detections.value == 2)
        #expect(search.total == oldTotal + 5)
        #expect(!search.isStale)
        #expect(!appearance.isStale)
        search.setVisible(true, document: fixture.document, scope: "test")
        appearance.setVisible(true, character: character, document: fixture.document)
        #expect(searches.value == 2)
        #expect(detections.value == 2)
        #expect(!search.isSearching)
        #expect(!appearance.isLoading)
        #expect(searchClock.delays.count == 2)
        #expect(appearanceClock.delays.count == 2)
    }

    @Test func visibleDocumentChangesWaitForExplicitSearch() async throws {
        let fixture = ReplacementFixture(), computations = SearchComputationCounter()
        let clock = WorkSearchTestClock()
        let search = WorkSearchSession(search: { query, document in
            computations.increment()
            return WorkTextSearch.search(query: query, in: document)
        }, sleep: clock.sleep)
        search.query = "猫"
        search.refresh(document: fixture.document, scope: "test")
        #expect(await clock.scheduled(0) == .milliseconds(250))
        clock.advance()
        try await waitForWorkSearchState { !search.isStale }
        let old = search.total
        for _ in 0 ..< 200 {
            search.markStale()
        }
        #expect(search.total == old)
        #expect(computations.value == 1)
        #expect(clock.delays.count == 1)
        search.refresh(document: fixture.document, scope: "test")
        #expect(await clock.scheduled(1) == .milliseconds(250))
        clock.advance()
        try await waitForWorkSearchState { !search.isStale }
        #expect(computations.value == 2)
    }

    @Test func snapshotFailureStaleTextAndScopeRejectWithoutMutation() async throws {
        let fixture = ReplacementFixture()
        let search = try await fixture.search()
        fixture.snapshotSucceeds = false
        #expect(await !(search.replace(using: fixture.host)))
        #expect(fixture.applied == 0)
        #expect(fixture.snapshots == 1)
        fixture.snapshotSucceeds = true
        fixture.document.chapters[0].episodes[0].content = "変更後"
        #expect(await !(search.replace(using: fixture.host)))
        #expect(fixture.snapshots == 1)
        fixture.document.chapters[0].episodes[0].content = "猫猫"
        fixture.valid = false
        #expect(await !(search.replace(using: fixture.host)))
        #expect(fixture.applied == 0)
        fixture.valid = true
        fixture.changeScopeDuringSnapshot = true
        #expect(await !(search.replace(using: fixture.host)))
        #expect(fixture.applied == 0)
    }

    @Test func oneMutationExcludedMatchAndPartialUndo() async throws {
        let fixture = ReplacementFixture()
        let search = try await fixture.search()
        let result = try #require(search.results.first), match = try #require(result.matches.first)
        search.setIncluded(false, match: match, in: result)
        #expect(await search.replace(using: fixture.host))
        #expect(fixture.document.chapters[0].episodes.map { $0.content } == ["猫犬", "犬"])
        #expect(fixture.applied == 1)
        #expect(fixture.snapshots == 1)
        #expect(search.canUndo)
        fixture.document.chapters[0].episodes[0].content = "後の編集"
        #expect(await search.undo(using: fixture.host))
        #expect(fixture.document.chapters[0].episodes.map { $0.content } == ["後の編集", "猫"])
        #expect(fixture.applied == 2)
        #expect(search.message?.contains("履歴（置換前のスナップショット）から復元できます") == true)
        #expect(!search.canUndo)
    }

    @Test func failedSaveBoundaryReplacesAnEarlierSuccessMessage() async throws {
        let fixture = ReplacementFixture()
        let search = try await fixture.search()
        #expect(await search.replace(using: fixture.host))
        let original = fixture.host
        let failing = WorkReplacementHost(scope: original.scope, validate: original.validate,
                                          document: original.document, boundary: { _ in false },
                                          snapshot: original.snapshot, apply: original.apply)
        #expect(await !(search.replace(using: failing)))
        #expect(search.message?.contains("入力確定・保存") == true)
    }

    @Test func debounceDiscardsOldSearchAndAppearance() async throws {
        let fixture = ReplacementFixture(), search = WorkSearchSession()
        search.query = "猫"
        search.refresh(document: fixture.document, scope: "old")
        search.query = "犬"
        fixture.document.chapters[0].episodes[0].content = "犬"
        search.refresh(document: fixture.document, scope: "new")
        try await Task.sleep(for: .milliseconds(450))
        #expect(search.scope == "new")
        #expect(search.total == 1)
        #expect(search.results.first?.source == "犬")
        let appearance = CharacterAppearanceSession()
        appearance.refresh(character: NovelCore.Character(name: "猫"), document: fixture.document)
        appearance.refresh(character: NovelCore.Character(name: "犬"), document: fixture.document)
        try await Task.sleep(for: .milliseconds(450))
        #expect(appearance.appearances.count == 1)
        #expect(appearance.appearances.first?.query == "犬")
    }
}

@MainActor
private final class ReplacementFixture {
    var document = NovelDocument.newDocument()
    var valid = true
    var snapshotSucceeds = true
    var changeScopeDuringSnapshot = false
    var snapshots = 0
    var applied = 0

    init() {
        document.chapters = [Chapter(title: "章", episodes: [Episode(content: "猫猫"), Episode(content: "猫")])]
    }

    var host: WorkReplacementHost {
        WorkReplacementHost(
            scope: "test",
            validate: { self.valid },
            document: { self.document },
            boundary: { operation in await operation() },
            snapshot: {
                self.snapshots += 1
                if self.changeScopeDuringSnapshot {
                    self.valid = false
                }
                return self.snapshotSucceeds
            },
            apply: { changes in
                self.applied += 1
                for change in changes {
                    self.document.updateEpisodeContent(change.after, for: change.episodeID, in: change.chapterID)
                }
                return true
            }
        )
    }

    func search() async throws -> WorkSearchSession {
        let search = WorkSearchSession()
        search.query = "猫"; search.replacement = "犬"
        search.refresh(document: document, scope: host.scope)
        try await Task.sleep(for: .milliseconds(450))
        #expect(search.total == 3)
        return search
    }
}

/// 合成作品の隔離SQLiteをread-onlyで確認する。AIのEdit journalを作らないことを検証。
func workSearchJournalCount(root: URL) throws -> Int {
    var database: OpaquePointer?
    let status = sqlite3_open_v2(
        root.appendingPathComponent("writing-assistant.sqlite").path,
        &database,
        SQLITE_OPEN_READONLY,
        nil
    )
    defer {
        if let database {
            sqlite3_close(database)
        }
    }
    #expect(status == SQLITE_OK)
    let opened = try #require(database)
    var statement: OpaquePointer?
    #expect(sqlite3_prepare_v2(opened, "SELECT COUNT(*) FROM edits", -1, &statement, nil) == SQLITE_OK)
    let query = try #require(statement)
    defer { sqlite3_finalize(query) }
    #expect(sqlite3_step(query) == SQLITE_ROW)
    return Int(sqlite3_column_int(query, 0))
}

private final class SearchComputationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
