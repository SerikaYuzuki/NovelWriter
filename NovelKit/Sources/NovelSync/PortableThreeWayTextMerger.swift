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

public struct PortableTextMergeConflict: Equatable, Sendable {
    public let reason: PortableTextMergeConflictReason
    public let proposedContent: String

    public init(reason: PortableTextMergeConflictReason, proposedContent: String) {
        self.reason = reason
        self.proposedContent = proposedContent
    }
}

public enum PortableTextMergeAnalysis: Equatable, Sendable {
    case merged(String)
    case conflict(PortableTextMergeConflict)
}

/// Unicode scalar座標と固定budgetだけを使う、provider/OS非依存の3-way merger。
/// Myers shortest-edit-scriptで各sideを複数hunkへ分け、非重複hunkは全て統合する。
/// budgetを超える場合は推測せず、local本文を確認用下書きとして返す。
public enum PortableThreeWayTextMerger {
    public static let maximumInputUTF8Bytes = 4 * 1024 * 1024
    public static let maximumInputScalarCount = 1_000_000
    public static let maximumEditDistance = PortableScalarDiff.maximumEditDistance
    public static let maximumDiffWork = PortableScalarDiff.maximumWork

    public static func merge(base: String, local: String, remote: String) -> PortableTextMergeResult {
        switch analyze(base: base, local: local, remote: remote) {
        case let .merged(content):
            .merged(content)
        case let .conflict(conflict):
            .conflict(conflict.reason)
        }
    }

    public static func analyze(
        base: String,
        local: String,
        remote: String
    ) -> PortableTextMergeAnalysis {
        guard inputsAreWithinLimits(base, local, remote) else {
            return conflict(.inputLimitExceeded, proposedContent: local)
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
        guard let localEdits = PortableScalarDiff.edits(
            base: baseScalars,
            variant: Array(local.unicodeScalars)
        ), let remoteEdits = PortableScalarDiff.edits(
            base: baseScalars,
            variant: Array(remote.unicodeScalars)
        ) else {
            return conflict(.ambiguousChanges, proposedContent: local)
        }
        return mergeEdits(base: baseScalars, local: localEdits, remote: remoteEdits)
    }

    private static func mergeEdits(
        base: [Unicode.Scalar],
        local: [PortableScalarDiff.Edit],
        remote: [PortableScalarDiff.Edit]
    ) -> PortableTextMergeAnalysis {
        var conflictingRemote: Set<Int> = []
        var reason: PortableTextMergeConflictReason?
        for (remoteIndex, remoteEdit) in remote.enumerated() {
            for localEdit in local {
                if localEdit == remoteEdit {
                    continue
                }
                if localEdit.range.isEmpty, remoteEdit.range.isEmpty,
                   localEdit.range.lowerBound == remoteEdit.range.lowerBound {
                    conflictingRemote.insert(remoteIndex)
                    if reason == nil {
                        reason = .sameInsertionPoint
                    }
                    continue
                }
                guard !editsAreDisjoint(localEdit, remoteEdit) else { continue }
                conflictingRemote.insert(remoteIndex)
                reason = .overlappingChanges
            }
        }

        let nonDuplicateRemote = remote.enumerated().filter { _, edit in
            !local.contains(edit)
        }
        if let reason {
            let safeRemote = nonDuplicateRemote.compactMap { index, edit in
                conflictingRemote.contains(index) ? nil : edit
            }
            return conflict(
                reason,
                proposedContent: applying(local + safeRemote, to: base)
            )
        }
        return .merged(applying(local + nonDuplicateRemote.map(\.element), to: base))
    }

    private static func applying(
        _ edits: [PortableScalarDiff.Edit],
        to base: [Unicode.Scalar]
    ) -> String {
        var result = base
        for edit in edits.sorted(by: editApplicationOrder) {
            result.replaceSubrange(edit.range, with: edit.replacement)
        }
        return String(String.UnicodeScalarView(result))
    }

    private static func editApplicationOrder(
        _ lhs: PortableScalarDiff.Edit,
        _ rhs: PortableScalarDiff.Edit
    ) -> Bool {
        if lhs.range.lowerBound != rhs.range.lowerBound {
            return lhs.range.lowerBound > rhs.range.lowerBound
        }
        return lhs.range.upperBound > rhs.range.upperBound
    }

    private static func editsAreDisjoint(
        _ first: PortableScalarDiff.Edit,
        _ second: PortableScalarDiff.Edit
    ) -> Bool {
        if first.range.isEmpty {
            let point = first.range.lowerBound
            return point <= second.range.lowerBound || point >= second.range.upperBound
        }
        if second.range.isEmpty {
            let point = second.range.lowerBound
            return point <= first.range.lowerBound || point >= first.range.upperBound
        }
        return first.range.upperBound <= second.range.lowerBound
            || second.range.upperBound <= first.range.lowerBound
    }

    private static func inputsAreWithinLimits(_ values: String...) -> Bool {
        values.allSatisfy { value in
            value.utf8.count <= maximumInputUTF8Bytes
                && value.unicodeScalars.count <= maximumInputScalarCount
        }
    }

    private static func conflict(
        _ reason: PortableTextMergeConflictReason,
        proposedContent: String
    ) -> PortableTextMergeAnalysis {
        .conflict(PortableTextMergeConflict(reason: reason, proposedContent: proposedContent))
    }
}
