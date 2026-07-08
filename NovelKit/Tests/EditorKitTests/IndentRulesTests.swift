@testable import EditorKit
import Foundation
import Testing

/// ``IndentRules``(docs/DESIGN.md 4.5)の単体テスト。AppKit / UIKit に依存しない
/// 純ロジックなので、macOS / iOS どちらの `swift test` 環境でも実行できる。
struct IndentRulesTests {
    // MARK: - R1: 通常行での改行

    @Test("R1: 非空白文字を含む行での改行は「\\n + 全角スペース」に置換される")
    func r1InsertsFullWidthSpaceAfterNewline() {
        let text = "こんにちは"
        let range = NSRange(location: text.utf16.count, length: 0)

        let action = IndentRules.action(for: "\n", in: text, range: range)

        #expect(action == .replace(range: range, text: "\n\u{3000}", caretOffset: 2))
    }

    @Test("R1: 行の途中で改行しても、新しい行の先頭にだけ全角スペースが入る")
    func r1InsertsAtMidLineNewline() {
        let text = "abcdef"
        // "abc" の直後に改行を挿入する。
        let range = NSRange(location: 3, length: 0)

        let action = IndentRules.action(for: "\n", in: text, range: range)

        #expect(action == .replace(range: range, text: "\n\u{3000}", caretOffset: 2))
    }

    @Test("R1: 複数行の本文でも、改行を挿入した行だけが判定対象になる")
    func r1UsesOnlyCurrentLine() {
        let text = "　　空白行\n本文"
        // 2行目("本文")の末尾で改行。
        let range = NSRange(location: (text as NSString).length, length: 0)

        let action = IndentRules.action(for: "\n", in: text, range: range)

        #expect(action == .replace(range: range, text: "\n\u{3000}", caretOffset: 2))
    }

    // MARK: - R2: 空白のみの行での改行

    @Test("R2: 全角スペースのみの行での改行は、行の空白を消して空行にする")
    func r2CleansFullWidthSpaceOnlyLine() {
        let text = "　　"
        let range = NSRange(location: text.utf16.count, length: 0)

        let action = IndentRules.action(for: "\n", in: text, range: range)

        let expectedRange = NSRange(location: 0, length: text.utf16.count)
        #expect(action == .replace(range: expectedRange, text: "\n", caretOffset: 1))
    }

    @Test("R2: 半角スペース・タブ混在の行でも空行として扱われる")
    func r2CleansMixedWhitespaceLine() {
        let text = " \t "
        let range = NSRange(location: text.utf16.count, length: 0)

        let action = IndentRules.action(for: "\n", in: text, range: range)

        let expectedRange = NSRange(location: 0, length: text.utf16.count)
        #expect(action == .replace(range: expectedRange, text: "\n", caretOffset: 1))
    }

    @Test("R2: 前の行がある場合でも、空白行のみが掃除される")
    func r2OnlyCleansCurrentWhitespaceLine() {
        let text = "本文\n　"
        let lineStart = "本文\n".utf16.count
        let range = NSRange(location: (text as NSString).length, length: 0)

        let action = IndentRules.action(for: "\n", in: text, range: range)

        let expectedRange = NSRange(location: lineStart, length: "　".utf16.count)
        #expect(action == .replace(range: expectedRange, text: "\n", caretOffset: 1))
    }

    @Test("R2: キャレットが空白行の途中にあっても、行全体の空白が置換される")
    func r2CaretInMiddleOfWhitespaceLine() {
        let text = "　　"
        // 2つの全角スペースの間にキャレットがある状態で改行。
        let range = NSRange(location: 1, length: 0)

        let action = IndentRules.action(for: "\n", in: text, range: range)

        let expectedRange = NSRange(location: 0, length: text.utf16.count)
        #expect(action == .replace(range: expectedRange, text: "\n", caretOffset: 1))
    }

    @Test("完全な空行(空白すら無い行)での改行はR1のインデントを付けない")
    func emptyLineNewlineDoesNotIndent() {
        let text = ""
        let range = NSRange(location: 0, length: 0)

        let action = IndentRules.action(for: "\n", in: text, range: range)

        #expect(action == .replace(range: NSRange(location: 0, length: 0), text: "\n", caretOffset: 1))
    }

    // MARK: - R3: 字下げ直後の鉤括弧

    @Test("R3: 全角スペース1つだけの行末で「を入力すると鉤括弧に置き換わる")
    func r3ReplacesFullWidthSpaceWithKagiBracket() {
        let text = "\u{3000}"
        let range = NSRange(location: text.utf16.count, length: 0)

        let action = IndentRules.action(for: "「", in: text, range: range)

        #expect(action == .replace(range: NSRange(location: 0, length: 1), text: "「", caretOffset: 1))
    }

    @Test("R3: 二重鉤括弧(『)でも同様に置き換わる")
    func r3ReplacesFullWidthSpaceWithDoubleKagiBracket() {
        let text = "\u{3000}"
        let range = NSRange(location: text.utf16.count, length: 0)

        let action = IndentRules.action(for: "『", in: text, range: range)

        #expect(action == .replace(range: NSRange(location: 0, length: 1), text: "『", caretOffset: 1))
    }

    @Test("R3: 複数行中の字下げ行でも、その行だけが対象になる")
    func r3OnlyAffectsCurrentIndentedLine() {
        let text = "前の行\n\u{3000}"
        let lineStart = "前の行\n".utf16.count
        let range = NSRange(location: (text as NSString).length, length: 0)

        let action = IndentRules.action(for: "「", in: text, range: range)

        #expect(action == .replace(range: NSRange(location: lineStart, length: 1), text: "「", caretOffset: 1))
    }

    @Test("R3対象外: キャレットが全角スペースの前(行末ではない)にあるときは介入しない")
    func r3DoesNotFireWhenCaretNotAtLineEnd() {
        let text = "\u{3000}"
        let range = NSRange(location: 0, length: 0)

        let action = IndentRules.action(for: "「", in: text, range: range)

        #expect(action == .allow)
    }

    @Test("R3対象外: 行の内容が全角スペース1つだけでなければ介入しない")
    func r3DoesNotFireWhenLineHasOtherContent() {
        let text = "\u{3000}あ"
        let range = NSRange(location: text.utf16.count, length: 0)

        let action = IndentRules.action(for: "「", in: text, range: range)

        #expect(action == .allow)
    }

    @Test("R3対象外: 行の途中への鉤括弧入力には介入しない")
    func r3DoesNotFireMidLine() {
        let text = "「あ」"
        let range = NSRange(location: 1, length: 0)

        let action = IndentRules.action(for: "「", in: text, range: range)

        #expect(action == .allow)
    }

    @Test("R3対象外: 選択範囲を置き換える形の鉤括弧入力には介入しない")
    func r3DoesNotFireForRangeReplacement() {
        let text = "\u{3000}"
        let range = NSRange(location: 0, length: 1)

        let action = IndentRules.action(for: "「", in: text, range: range)

        #expect(action == .allow)
    }

    // MARK: - 対象外の入力全般

    @Test("対象外: 複数文字の挿入(ペースト相当)には介入しない")
    func multiCharacterInsertionIsAllowed() {
        let text = "本文"
        let range = NSRange(location: text.utf16.count, length: 0)

        let action = IndentRules.action(for: "追記文\n", in: text, range: range)

        #expect(action == .allow)
    }

    @Test("対象外: 削除(空文字列への置換)には介入しない")
    func deletionIsAllowed() {
        let text = "本文"
        let range = NSRange(location: 0, length: 1)

        let action = IndentRules.action(for: "", in: text, range: range)

        #expect(action == .allow)
    }

    @Test("対象外: 改行・鉤括弧以外の1文字挿入には介入しない")
    func otherSingleCharacterInsertionIsAllowed() {
        let text = "本文"
        let range = NSRange(location: text.utf16.count, length: 0)

        let action = IndentRules.action(for: "。", in: text, range: range)

        #expect(action == .allow)
    }

    // MARK: - 絵文字・サロゲートペアを含む本文での安全性

    @Test("絵文字を含む行での改行(R1)でもrangeが壊れず、正しい位置に挿入される")
    func emojiLineTriggersR1Safely() {
        let text = "😀本文"
        let range = NSRange(location: (text as NSString).length, length: 0)

        let action = IndentRules.action(for: "\n", in: text, range: range)

        #expect(action == .replace(range: range, text: "\n\u{3000}", caretOffset: 2))
    }

    @Test("絵文字を含む前の行があっても、字下げ行(R3)の判定・置換範囲が正しい")
    func emojiPrecedingLineDoesNotBreakR3() {
        let text = "😀先頭行\n\u{3000}"
        let lineStart = ("😀先頭行\n" as NSString).length
        let range = NSRange(location: (text as NSString).length, length: 0)

        let action = IndentRules.action(for: "『", in: text, range: range)

        #expect(action == .replace(range: NSRange(location: lineStart, length: 1), text: "『", caretOffset: 1))
    }

    @Test("結合絵文字(ZWJシーケンス)を含む行でもR2の空白判定・置換範囲が壊れない")
    func zwjEmojiDoesNotBreakR2() {
        // 👨‍👩‍👧‍👦 (family) は複数コードポイント・複数UTF-16単位のZWJシーケンス。
        let family = "👨‍👩‍👧‍👦"
        let text = "\(family)\n　"
        let lineStart = ("\(family)\n" as NSString).length
        let range = NSRange(location: (text as NSString).length, length: 0)

        let action = IndentRules.action(for: "\n", in: text, range: range)

        let expectedRange = NSRange(location: lineStart, length: "　".utf16.count)
        #expect(action == .replace(range: expectedRange, text: "\n", caretOffset: 1))
    }
}
