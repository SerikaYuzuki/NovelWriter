import Foundation

enum AIProofreadingDiffSegmentKind: Equatable {
    case unchanged
    case removed
    case inserted
}

enum AIProofreadingDiffDetail: Equatable {
    case character
    case condensed
}

struct AIProofreadingDiffSegment: Equatable {
    let kind: AIProofreadingDiffSegmentKind
    let text: String
}

/// 原文と提案を別々に再構成できる、表示専用の文字単位差分。
///
/// `CollectionDifference`のoffsetだけを表示用segmentへ変換し、原稿やAI結果を
/// 正規化しない。色だけでなく削除／追加ラベルと装飾を併用するUIで使う。
struct AIProofreadingDiff: Equatable {
    /// Myers差分をUIのMainActorで安全に処理できる小さな範囲へ限定する。
    /// これを超える場合もexactな再構成を保ち、共通prefix／suffix間を一つの変更区間として表示する。
    static let detailedCharacterLimit = 2000

    let originalSegments: [AIProofreadingDiffSegment]
    let proposalSegments: [AIProofreadingDiffSegment]
    let detail: AIProofreadingDiffDetail

    init(source: String, replacement: String) {
        let sourceCharacters = Array(source)
        let replacementCharacters = Array(replacement)
        let combinedCount = sourceCharacters.count.addingReportingOverflow(replacementCharacters.count)

        if !combinedCount.overflow, combinedCount.partialValue <= Self.detailedCharacterLimit {
            let detailed = Self.makeDetailedSegments(
                source: sourceCharacters,
                replacement: replacementCharacters
            )
            originalSegments = detailed.original
            proposalSegments = detailed.proposal
            detail = .character
        } else {
            let condensed = Self.makeCondensedSegments(
                source: sourceCharacters,
                replacement: replacementCharacters
            )
            originalSegments = condensed.original
            proposalSegments = condensed.proposal
            detail = .condensed
        }
    }

    var hasChanges: Bool {
        originalSegments.contains(where: { $0.kind == .removed }) ||
            proposalSegments.contains(where: { $0.kind == .inserted })
    }

    var removedText: String {
        originalSegments
            .filter { $0.kind == .removed }
            .map(\.text)
            .joined()
    }

    var insertedText: String {
        proposalSegments
            .filter { $0.kind == .inserted }
            .map(\.text)
            .joined()
    }

    private static func makeDetailedSegments(
        source: [Character],
        replacement: [Character]
    ) -> (original: [AIProofreadingDiffSegment], proposal: [AIProofreadingDiffSegment]) {
        let difference = replacement.difference(from: source)
        var removedOffsets = Set<Int>()
        var insertedOffsets = Set<Int>()

        for change in difference {
            switch change {
            case let .remove(offset, _, _):
                removedOffsets.insert(offset)
            case let .insert(offset, _, _):
                insertedOffsets.insert(offset)
            }
        }

        let original = makeSegments(
            from: source,
            changedOffsets: removedOffsets,
            changedKind: .removed
        )
        let proposal = makeSegments(
            from: replacement,
            changedOffsets: insertedOffsets,
            changedKind: .inserted
        )
        return (original, proposal)
    }

    private static func makeCondensedSegments(
        source: [Character],
        replacement: [Character]
    ) -> (original: [AIProofreadingDiffSegment], proposal: [AIProofreadingDiffSegment]) {
        var prefixCount = 0
        while prefixCount < source.count,
              prefixCount < replacement.count,
              source[prefixCount] == replacement[prefixCount]
        {
            prefixCount += 1
        }

        var suffixCount = 0
        while suffixCount < source.count - prefixCount,
              suffixCount < replacement.count - prefixCount,
              source[source.count - suffixCount - 1] == replacement[replacement.count - suffixCount - 1]
        {
            suffixCount += 1
        }

        return (
            makeCondensedSide(
                characters: source,
                prefixCount: prefixCount,
                suffixCount: suffixCount,
                changedKind: .removed
            ),
            makeCondensedSide(
                characters: replacement,
                prefixCount: prefixCount,
                suffixCount: suffixCount,
                changedKind: .inserted
            )
        )
    }

    private static func makeSegments(
        from characters: [Character],
        changedOffsets: Set<Int>,
        changedKind: AIProofreadingDiffSegmentKind
    ) -> [AIProofreadingDiffSegment] {
        var segments: [AIProofreadingDiffSegment] = []

        for (offset, character) in characters.enumerated() {
            let kind: AIProofreadingDiffSegmentKind = changedOffsets.contains(offset)
                ? changedKind
                : .unchanged
            append(String(character), kind: kind, to: &segments)
        }

        return segments
    }

    private static func makeCondensedSide(
        characters: [Character],
        prefixCount: Int,
        suffixCount: Int,
        changedKind: AIProofreadingDiffSegmentKind
    ) -> [AIProofreadingDiffSegment] {
        var segments: [AIProofreadingDiffSegment] = []
        append(String(characters[..<prefixCount]), kind: .unchanged, to: &segments)

        let changedEnd = characters.count - suffixCount
        append(String(characters[prefixCount ..< changedEnd]), kind: changedKind, to: &segments)
        append(String(characters[changedEnd...]), kind: .unchanged, to: &segments)
        return segments
    }

    private static func append(
        _ text: String,
        kind: AIProofreadingDiffSegmentKind,
        to segments: inout [AIProofreadingDiffSegment]
    ) {
        guard !text.isEmpty else { return }
        if let last = segments.last, last.kind == kind {
            segments[segments.count - 1] = AIProofreadingDiffSegment(
                kind: kind,
                text: last.text + text
            )
        } else {
            segments.append(AIProofreadingDiffSegment(kind: kind, text: text))
        }
    }
}
