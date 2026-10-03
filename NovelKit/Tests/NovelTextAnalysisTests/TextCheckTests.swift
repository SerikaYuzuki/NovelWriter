import Foundation
import NovelCore
import NovelTextAnalysis
import Testing

struct TextCheckTests {
    private func document(_ texts: [String], characters: [NovelCore.Character] = []) -> NovelDocument {
        var document = NovelDocument.newDocument()
        document.chapters = [Chapter(title: "章", episodes: texts.enumerated().map { Episode(title: "話\($0.offset)", content: $0.element) })]
        document.characters = characters
        return document
    }

    @Test(arguments: [
        ("　…", TextCheckRule.oddLeader), ("　―――", .oddDash),
        ("　！？続く", .punctuationSpace), ("「終わり。」", .periodBeforeBracket),
        ("『終わり。』", .periodBeforeBracket), ("　!", .halfWidthPunctuation),
        ("　?", .halfWidthPunctuation), ("　。。", .duplicatePunctuation),
        ("　、、", .duplicatePunctuation), ("地の文", .indentation)
    ])
    func symbols(text: String, rule: TextCheckRule) {
        let issues = TextChecker().check(document([text]))
        #expect(issues.contains { $0.rule == rule })
        for occurrence in issues.flatMap(\.occurrences) {
            #expect(Range(occurrence.match.range, in: occurrence.result.source) != nil)
        }
    }

    @Test func symbolBoundariesAndNotation() {
        let text = "「！」\n『？』\n（！？）\n　！？\n　！？　続く\n　……――\n\n会話でない\n「会話」\n『会話』\n（括弧）\n　｜親!?…。《読み！？》\n　｜…《・》｜！《・》\n　本文末！"
        let issues = TextChecker().check(document([text]))
        #expect(issues.count(where: { $0.rule == .indentation }) == 1)
        #expect(issues.allSatisfy { $0.rule == .indentation })
    }

    @Test func newlineCRLFAndUnicodeRanges() {
        let doc = document(["　🐈‍⬛！？続く\r\n「会話」\r地の文"])
        let issues = TextChecker().check(doc)
        let space = issues.first { $0.rule == .punctuationSpace }
        #expect(space?.occurrences.first?.match.range == NSRange(location: 5, length: 2))
        #expect(issues.count(where: { $0.rule == .indentation }) == 1)
    }

    @Test func dictionaryBothFormsConjugationsCountsAndOrder() throws {
        let doc = document(["　できた。出来た。出来る。できる。できない。出来ない。", "　出来る。"])
        let issues = TextChecker().check(doc).filter { $0.rule == .dictionaryVariation }
        #expect(issues.count == 3)
        let forms = try #require(issues.first { $0.variants.contains { $0.text == "出来る" } })
        #expect(forms.title == "出来る 2件 / できる 1件")
        #expect(forms.replacement?.query == "できる")
        #expect(forms.replacement?.replacement == "出来る")
        #expect(forms.occurrences.map { $0.result.episodeTitle } == ["話0", "話0", "話1"])
        #expect(TextChecker().check(document(["　出来る。出来た。出来ない。"])).allSatisfy { $0.rule != .dictionaryVariation })
        #expect(TextChecker().check(document(["　仕事のこと。時間のとき。"])).allSatisfy { $0.rule != .dictionaryVariation })
    }

    @Test func fakeReadingAgreementAndNoise() throws {
        let text = "　綺麗 綺麗 綺麗 きれい きれい 奇麗 漢字 かんじ から カラ 一 い 12 十二 ！！"
        let fake = try FakeJapaneseTokenizer(readings: [
            "綺麗": "きれい", "きれい": "きれい", "奇麗": "きれい",
            "漢字": "かんじ", "かんじ": "かんじ", "から": "から", "カラ": "から",
            "一": "い", "い": "い", "12": "じゅうに", "十二": "じゅうに", "！！": "じゅうに"
        ])
        let issues = TextChecker(tokenizer: fake).check(document([text])).filter { $0.rule == .readingVariation }
        #expect(issues.count == 1)
        let issue = try #require(issues.first)
        #expect(issue.title == "綺麗 3件 / きれい 2件")
        #expect(issue.occurrences.count == 5)
        #expect(issue.replacement?.query == "きれい")
    }

    @Test func realTokenizerRepresentativeReadingIsJapanese() {
        let tokens = AppleJapaneseTokenizer().tokens(in: "綺麗な花。きれいな空。")
        #expect(!tokens.isEmpty)
        #expect(tokens.contains { $0.text == "綺麗" || $0.text == "きれい" })
        #expect(tokens.contains { $0.reading?.contains("きれい") == true })
        #expect(tokens.allSatisfy { Range($0.range, in: "綺麗な花。きれいな空。") != nil })
    }

    @Test func characterTypoScriptLengthFrequencyAndRegisteredNames() throws {
        let characters = [NovelCore.Character(name: "レオン", kana: "れおん"), NovelCore.Character(name: "美咲"), NovelCore.Character(name: "レオナ")]
        let fake = try FakeJapaneseTokenizer(readings: [:])
        let text = "　レオン レオン レオン レオソ レオナ れおン レオン様 れおん れおん れおそ 美咲 美咲 美崎 美さ 美沙子"
        let issues = TextChecker(tokenizer: fake).check(document([text], characters: characters)).filter { $0.rule == .characterTypo }
        #expect(issues.count == 3)
        #expect(issues.contains { $0.title.contains("レオソ") })
        #expect(issues.contains { $0.title.contains("美崎") })
        #expect(issues.contains { $0.title.contains("れおそ") })
        #expect(TextChecker(tokenizer: fake).check(document(["　レオン レオソ"], characters: characters)).allSatisfy { $0.rule != .characterTypo })
        #expect(TextChecker(tokenizer: fake).check(document(["　レオン レオソ レオソ"], characters: characters)).allSatisfy { $0.rule != .characterTypo })
    }

    @Test func dialogueExclusionNestedAcrossLinesAndSymbolsUnaffected() throws {
        let text = "　出来る。レオン。レオン。\n「できる。『レオソ』\n…」"
        let doc = document([text], characters: [NovelCore.Character(name: "レオン")])
        let checker = TextChecker()
        let all = checker.check(doc)
        let excluded = checker.check(doc, options: TextCheckOptions(excludeDialogue: true))
        #expect(all.contains { $0.rule == .dictionaryVariation })
        #expect(all.contains { $0.rule == .characterTypo })
        #expect(excluded.allSatisfy { $0.rule != .dictionaryVariation && $0.rule != .characterTypo })
        #expect(all.filter { $0.rule == .oddLeader } == excluded.filter { $0.rule == .oddLeader })
        let fake = try FakeJapaneseTokenizer(readings: ["綺麗": "きれい", "きれい": "きれい"])
        let readings = document(["　綺麗 綺麗\n「きれい きれい」"])
        #expect(TextChecker(tokenizer: fake).check(readings).contains { $0.rule == .readingVariation })
        #expect(TextChecker(tokenizer: fake).check(readings, options: TextCheckOptions(excludeDialogue: true)).allSatisfy { $0.rule != .readingVariation })
    }

    @Test func rubyParentsAreCheckedButReadingsAreNotWords() {
        let checker = TextChecker()
        #expect(checker.check(document(["　｜出来る《できる》 出来る"])).allSatisfy { $0.rule != .dictionaryVariation })
        #expect(checker.check(document(["　｜出来る《できる》 できる"])).contains { $0.rule == .dictionaryVariation })
    }

    @Test func currentEpisodeScope() {
        let doc = document(["　出来る。", "　できる。"])
        #expect(TextChecker().check(doc).contains { $0.rule == .dictionaryVariation })
        #expect(TextChecker().check(doc, episodeID: doc.chapters[0].episodes[0].id).isEmpty)
    }

    @Test func threeHundredThousandCharactersPerformance() {
        let sentence = "　静かな風が遠くの森を抜けて流れていた。\n"
        let block = String(repeating: sentence, count: 200) + "　出来る。出来る。できる。…\n"
        let text = String(repeating: block, count: 300_000 / block.count + 1)
        let doc = document([text])
        let clock = ContinuousClock(), start = clock.now
        let issues = TextChecker().check(doc)
        let elapsed = start.duration(to: clock.now)
        print("TextCheck 300k: \(elapsed), \(issues.count) groups")
        #expect(!issues.isEmpty)
        #expect(elapsed < .seconds(30))
    }
}

private struct FakeJapaneseTokenizer: JapaneseTextTokenizing {
    let readings: [String: String]
    private let regex: NSRegularExpression

    init(readings: [String: String]) throws {
        self.readings = readings
        regex = try NSRegularExpression(pattern: "[^\\s、。「」『』]+")
    }

    func tokens(in text: String) -> [JapaneseTextToken] {
        regex.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)).map {
            let value = (text as NSString).substring(with: $0.range)
            return JapaneseTextToken(text: value, reading: readings[value], range: $0.range)
        }
    }
}
