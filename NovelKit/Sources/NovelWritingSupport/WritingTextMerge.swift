import Foundation

/// Maps a bounded replacement through unrelated concurrent edits. Ambiguous or
/// changed surrounding context fails closed; no fuzzy matching or model judgement.
enum WritingTextMerge {
    static func apply(before: String, after: String, current: String) throws -> String {
        if current == before {
            return after
        }
        let old = Array(before), new = Array(after)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < min(old.count - prefix, new.count - prefix), old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }
        let left = String(old[max(0, prefix - 32) ..< prefix])
        let right = String(old[(old.count - suffix) ..< min(old.count, old.count - suffix + 32)])
        let original = String(old[prefix ..< old.count - suffix])
        let replacement = String(new[prefix ..< new.count - suffix])
        let needle = left + original + right
        guard !needle.isEmpty, let match = current.range(of: needle),
              current.range(of: needle, range: current.index(after: match.lowerBound) ..< current.endIndex) == nil else {
            throw WritingError.changedTarget
        }
        // The original start/end remain boundaries when no outer anchor exists.
        if prefix == 0, match.lowerBound != current.startIndex {
            throw WritingError.changedTarget
        }
        if suffix == 0, match.upperBound != current.endIndex {
            throw WritingError.changedTarget
        }
        let start = current.index(match.lowerBound, offsetBy: left.count)
        let end = current.index(start, offsetBy: original.count)
        return String(current[..<start]) + replacement + String(current[end...])
    }
}
