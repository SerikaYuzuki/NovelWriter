@testable import FUMINIWAExperimental
import Testing

@Test("文字単位差分は原文と提案をexactに再構成する")
func diffReconstructsExactSourceAndReplacement() {
    let source = "猫は出来る。。\n次の行"
    let replacement = "猫はできる。\n次の行"
    let difference = AIProofreadingDiff(source: source, replacement: replacement)

    #expect(difference.hasChanges)
    #expect(difference.detail == .character)
    #expect(difference.originalSegments.map(\.text).joined() == source)
    #expect(difference.proposalSegments.map(\.text).joined() == replacement)
    #expect(difference.originalSegments.contains(where: { $0.kind == .removed }))
    #expect(difference.proposalSegments.contains(where: { $0.kind == .inserted }))
    #expect(!difference.removedText.isEmpty)
    #expect(!difference.insertedText.isEmpty)
}

@Test("変更がない場合は追加削除を表示しない")
func diffReportsNoChangesForIdenticalText() {
    let text = "　同じ本文です。"
    let difference = AIProofreadingDiff(source: text, replacement: text)

    #expect(!difference.hasChanges)
    #expect(difference.originalSegments == [.init(kind: .unchanged, text: text)])
    #expect(difference.proposalSegments == [.init(kind: .unchanged, text: text)])
}

@Test("絵文字を分割せずCharacter単位で削除を示す")
func diffKeepsExtendedGraphemeClustersIntact() {
    let difference = AIProofreadingDiff(source: "猫🐈です", replacement: "猫です")

    let removed = difference.originalSegments
        .filter { $0.kind == .removed }
        .map(\.text)
        .joined()

    #expect(removed == "🐈")
    #expect(difference.removedText == "🐈")
    #expect(difference.insertedText.isEmpty)
    #expect(difference.proposalSegments.map(\.text).joined() == "猫です")
}

@Test("長い範囲は共通前後を残す線形差分へ切り替える")
func longDiffUsesCondensedExactRepresentation() {
    let commonPrefix = String(repeating: "前", count: 1000)
    let commonSuffix = String(repeating: "後", count: 1000)
    let source = commonPrefix + String(repeating: "旧", count: 10000) + commonSuffix
    let replacement = commonPrefix + String(repeating: "新", count: 10000) + commonSuffix

    let difference = AIProofreadingDiff(source: source, replacement: replacement)

    #expect(difference.detail == .condensed)
    #expect(difference.originalSegments.map(\.text).joined() == source)
    #expect(difference.proposalSegments.map(\.text).joined() == replacement)
    #expect(difference.originalSegments == [
        .init(kind: .unchanged, text: commonPrefix),
        .init(kind: .removed, text: String(repeating: "旧", count: 10000)),
        .init(kind: .unchanged, text: commonSuffix)
    ])
    #expect(difference.proposalSegments == [
        .init(kind: .unchanged, text: commonPrefix),
        .init(kind: .inserted, text: String(repeating: "新", count: 10000)),
        .init(kind: .unchanged, text: commonSuffix)
    ])
}
