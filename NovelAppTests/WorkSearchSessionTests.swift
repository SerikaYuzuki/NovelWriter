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

@MainActor
struct WorkSearchSessionTests {
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
