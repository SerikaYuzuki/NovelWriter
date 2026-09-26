@testable import EditorKit
import Foundation
import Testing

@Test
func proofreadingRangesPreserveUnicodeAndUnchangedEdges() {
    #expect(ProofreadingChanges.insertedRanges(original: "前あ後", revised: "前👩‍👩‍👧‍👦後") == [NSRange(location: 1, length: 11)])
    #expect(ProofreadingChanges.insertedRanges(original: "前あ後", revised: "前後").isEmpty)
    #expect(ProofreadingChanges.insertedRanges(original: "同じ", revised: "同じ").isEmpty)
    let edge = String(repeating: "あ", count: 100_000)
    #expect(ProofreadingChanges.insertedRanges(original: edge + "旧" + edge, revised: edge + "新" + edge) == [NSRange(location: edge.utf16.count, length: 1)])
}

@Test
func largeProofreadingRewriteHighlightsOnlyChangedBlock() {
    let old = String(repeating: "旧", count: 5000)
    let new = String(repeating: "新", count: 5000)
    #expect(ProofreadingChanges.insertedRanges(original: "前" + old + "後", revised: "前" + new + "後") == [NSRange(location: 1, length: 5000)])
}

@Test("離れた校正箇所の間にある長い本文には色を付けない", arguments: ["", "\n"])
func proofreadingSeparatesDistantChanges(separator: String) {
    let unchanged = String(repeating: "変わらない本文。" + separator, count: 300)
    let original = "前誤" + unchanged + "字" + unchanged + "旧後"
    let revised = "前正" + unchanged + "👩‍👩‍👧‍👦" + unchanged + "新後"
    let second = 2 + unchanged.utf16.count
    #expect(ProofreadingChanges.insertedRanges(original: original, revised: revised) == [
        NSRange(location: 1, length: 1), NSRange(location: second, length: 11),
        NSRange(location: second + 11 + unchanged.utf16.count, length: 1)
    ])
}

@Test("離れた削除だけの校正では残った本文を着色しない")
func proofreadingDistantDeletionsHaveNoHighlights() {
    let unchanged = String(repeating: "残る文章。", count: 500)
    #expect(ProofreadingChanges.insertedRanges(original: "前誤" + unchanged + "字後", revised: "前" + unchanged + "後").isEmpty)
}

@Test("長い一段落の校正でも全体を着色せず、変更文字の位置を保つ")
func proofreadingLongParagraphKeepsExactRanges() {
    let unchanged = String(repeating: "あ", count: 100_000)
    #expect(ProofreadingChanges.insertedRanges(original: "旧" + unchanged + "字", revised: "新" + unchanged + "文") == [
        NSRange(location: 0, length: 1), NSRange(location: 100_001, length: 1)
    ])
}
