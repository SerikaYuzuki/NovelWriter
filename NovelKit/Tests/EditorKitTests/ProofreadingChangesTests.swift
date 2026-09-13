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
