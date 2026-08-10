import Foundation

public enum PortableTextMergeConflictReason: String, Codable, Sendable {
    case inputLimitExceeded
    case sameInsertionPoint
    case overlappingChanges
    case ambiguousChanges
}

public enum PortableTextMergeResult: Equatable, Sendable {
    case merged(String)
    case conflict(PortableTextMergeConflictReason)
}

/// Unicode scalarを共通座標にする、保守的で決定論的な3-way merger。
/// 各sideを単一連続editとして表現でき、base上で明確に非重複な場合だけauto mergeする。
/// 正規化、grapheme分割、clock、locale、OS固有diff APIには依存しない。
public enum PortableThreeWayTextMerger {
    public static let maximumInputUTF8Bytes = 4 * 1024 * 1024
    public static let maximumInputScalarCount = 1_000_000

    public static func merge(base: String, local: String, remote: String) -> PortableTextMergeResult {
        guard inputsAreWithinLimits(base, local, remote) else {
            return .conflict(.inputLimitExceeded)
        }
        if local == remote {
            return .merged(local)
        }
        if local == base {
            return .merged(remote)
        }
        if remote == base {
            return .merged(local)
        }

        let baseScalars = Array(base.unicodeScalars)
        let localScalars = Array(local.unicodeScalars)
        let remoteScalars = Array(remote.unicodeScalars)
        let localEdit = contiguousEdit(base: baseScalars, variant: localScalars)
        let remoteEdit = contiguousEdit(base: baseScalars, variant: remoteScalars)

        guard let localEdit, let remoteEdit else {
            return .conflict(.ambiguousChanges)
        }
        if localEdit.range.isEmpty, remoteEdit.range.isEmpty,
           localEdit.range.lowerBound == remoteEdit.range.lowerBound {
            return .conflict(.sameInsertionPoint)
        }
        guard editsAreDisjoint(localEdit, remoteEdit) else {
            return .conflict(.overlappingChanges)
        }

        var merged = baseScalars
        for edit in [localEdit, remoteEdit].sorted(by: { lhs, rhs in
            lhs.range.lowerBound > rhs.range.lowerBound
        }) {
            merged.replaceSubrange(edit.range, with: edit.replacement)
        }
        return .merged(String(String.UnicodeScalarView(merged)))
    }

    private struct ScalarEdit {
        let range: Range<Int>
        let replacement: [Unicode.Scalar]
    }

    private static func inputsAreWithinLimits(_ values: String...) -> Bool {
        values.allSatisfy { value in
            value.utf8.count <= maximumInputUTF8Bytes
                && value.unicodeScalars.count <= maximumInputScalarCount
        }
    }

    private static func contiguousEdit(
        base: [Unicode.Scalar],
        variant: [Unicode.Scalar]
    ) -> ScalarEdit? {
        var prefix = 0
        let commonLimit = min(base.count, variant.count)
        while prefix < commonLimit, base[prefix] == variant[prefix] {
            prefix += 1
        }

        var suffix = 0
        while suffix < base.count - prefix,
              suffix < variant.count - prefix,
              base[base.count - suffix - 1] == variant[variant.count - suffix - 1] {
            suffix += 1
        }

        let baseUpper = base.count - suffix
        let variantUpper = variant.count - suffix
        guard prefix <= baseUpper, prefix <= variantUpper else { return nil }
        return ScalarEdit(
            range: prefix ..< baseUpper,
            replacement: Array(variant[prefix ..< variantUpper])
        )
    }

    private static func editsAreDisjoint(_ first: ScalarEdit, _ second: ScalarEdit) -> Bool {
        if first.range.isEmpty {
            let point = first.range.lowerBound
            return point < second.range.lowerBound || point > second.range.upperBound
        }
        if second.range.isEmpty {
            let point = second.range.lowerBound
            return point < first.range.lowerBound || point > first.range.upperBound
        }
        return first.range.upperBound <= second.range.lowerBound
            || second.range.upperBound <= first.range.lowerBound
    }
}
