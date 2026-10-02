#if os(macOS)
@testable import FUMINIWA
#else
@testable import FUMINIWAIOS
#endif
import Foundation
import NovelCore
import NovelTextAnalysis
import Testing

@MainActor
struct TextCheckSessionTests {
    @Test func ignoreRestorePersistenceAndWorkIsolation() async throws {
        let suite = "TextCheckTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let work = UUID(), other = UUID()
        var doc = NovelDocument.newDocument()
        doc.chapters[0].episodes[0].content = "　… 出来る 出来る できる"
        let session = TextCheckSession(defaults: defaults)
        await session.check(document: doc, workID: work, scope: "one", episodeID: nil) { true }
        let variation = try #require(session.results.first { $0.rule == .dictionaryVariation })
        let symbol = try #require(session.results.first { $0.rule == .oddLeader })
        session.ignore(variation)
        session.ignore(symbol, occurrence: symbol.occurrences[0])
        #expect(session.isEmpty)
        let reloaded = TextCheckSession(defaults: defaults)
        reloaded.bind(workID: work, scope: "one")
        #expect(reloaded.ignored.count == 2)
        await reloaded.check(document: doc, workID: work, scope: "one", episodeID: nil) { true }
        #expect(reloaded.isEmpty)
        reloaded.restoreIgnored(variation.id)
        #expect(reloaded.count == 3)
        session.bind(workID: other, scope: "two")
        #expect(session.ignored.isEmpty)
        #expect(session.results.isEmpty)
        session.bind(workID: work, scope: "new account")
        #expect(session.ignored.count == 1) // 無視は作品単位。account切替で解析結果は捨てる。
        #expect(!session.hasChecked)
        session.bind(workID: nil, scope: "closed")
        #expect(session.ignored.isEmpty)
        #expect(defaults.dictionaryRepresentation().keys.count(where: { $0.hasPrefix("fuminiwa.textcheck.ignored.") }) == 1)
    }

    @Test func manualOnlyInvalidationAndReplacementPrefill() async throws {
        let defaults = try #require(UserDefaults(suiteName: "TextCheckTests.\(UUID())"))
        let session = TextCheckSession(defaults: defaults), search = WorkSearchSession(), work = UUID()
        var doc = NovelDocument.newDocument()
        doc.chapters[0].episodes[0].content = "　出来る 出来る できる"
        session.synchronize(document: doc, workID: work, scope: "scope")
        #expect(session.results.isEmpty)
        #expect(!session.isChecking)
        await session.check(document: doc, workID: work, scope: "scope", episodeID: nil) { true }
        let issue = try #require(session.results.first { $0.rule == .dictionaryVariation })
        #expect(session.prefillReplacement(issue, search: search, expectedScope: "scope"))
        #expect(search.query == "できる")
        #expect(search.replacement == "出来る")
        #expect(!search.isReplacing)
        #expect(!session.prefillReplacement(issue, search: search, expectedScope: "stale"))
        doc.chapters[0].episodes[0].content += "。"
        session.synchronize(document: doc, workID: work, scope: "scope")
        #expect(!session.hasChecked)
        #expect(session.results.isEmpty)
        #expect(!session.isChecking)
        #expect(!session.prefillReplacement(issue, search: search, expectedScope: "scope"))
        await session.check(document: doc, workID: work, scope: "scope", episodeID: nil) { true }
        session.excludeDialogue = true
        #expect(!session.hasChecked)
        #expect(!session.isChecking)
        #expect(session.results.isEmpty)
    }

    @Test func oldWorkerAndFailedValidationAreDiscarded() async throws {
        let defaults = try #require(UserDefaults(suiteName: "TextCheckTests.\(UUID())"))
        let session = TextCheckSession(defaults: defaults), work = UUID()
        var doc = NovelDocument.newDocument(); doc.chapters[0].episodes[0].content = "　…"
        await session.check(document: doc, workID: work, scope: "one", episodeID: nil) { false }
        #expect(session.results.isEmpty)
        #expect(!session.hasChecked)
        let captured = doc
        let task = Task {
            await session.check(document: captured, workID: work, scope: "one", episodeID: nil,
                                checker: TextChecker(tokenizer: SlowTokenizer())) { true }
        }
        for _ in 0 ..< 100 where !session.isChecking {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(session.isChecking)
        session.bind(workID: UUID(), scope: "two")
        await task.value
        #expect(session.scope == "two")
        #expect(session.results.isEmpty)
        #expect(!session.isChecking)
    }
}

private struct SlowTokenizer: JapaneseTextTokenizing {
    func tokens(in _: String) -> [JapaneseTextToken] {
        Thread.sleep(forTimeInterval: 0.1)
        return []
    }
}
