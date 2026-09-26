import Foundation

/// Character boundaries preserve composed Japanese text and emoji; ranges use native UTF-16 offsets.
public enum ProofreadingChanges {
    /// Match unchanged lines first, then compare characters within each changed block.
    /// Distance between corrections must never turn unchanged manuscript into a highlight.
    public static func insertedRanges(original: String, revised: String) -> [NSRange] {
        let before = lines(original), after = lines(revised)
        let changes = changedOffsets(before: before, after: after)
        var oldIndex = 0, newIndex = 0, offset = 0
        var ranges: [NSRange] = []
        while oldIndex < before.count || newIndex < after.count {
            let oldStart = oldIndex, newStart = newIndex
            while changes.removed.contains(oldIndex) {
                oldIndex += 1
            }
            while changes.inserted.contains(newIndex) {
                newIndex += 1
            }
            let changedText = after[newStart ..< newIndex].joined()
            for range in characterRanges(original: before[oldStart ..< oldIndex].joined(), revised: changedText) {
                append(NSRange(location: offset + range.location, length: range.length), to: &ranges)
            }
            offset += changedText.utf16.count
            if newIndex < after.count {
                offset += after[newIndex].utf16.count
                oldIndex += 1; newIndex += 1
            }
        }
        return ranges
    }

    private static func lines(_ text: String) -> [String] {
        var result: [String] = [], start = text.startIndex
        for index in text.indices where text[index].isNewline {
            let end = text.index(after: index)
            result.append(String(text[start ..< end]))
            start = end
        }
        if start < text.endIndex {
            result.append(String(text[start...]))
        }
        return result
    }

    private static func characterRanges(original: String, revised: String) -> [NSRange] {
        let before = Array(original)
        let after = Array(revised)
        var start = 0
        while start < min(before.count, after.count), before[start] == after[start] {
            start += 1
        }
        var oldEnd = before.count
        var newEnd = after.count
        while oldEnd > start, newEnd > start, before[oldEnd - 1] == after[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }
        guard newEnd > start else { return [] }
        let prefixLength = after[..<start].reduce(0) { $0 + String($1).utf16.count }
        let changed = after[start ..< newEnd]
        let inserted = changedOffsets(before: Array(before[start ..< oldEnd]), after: Array(changed)).inserted
        var ranges: [NSRange] = []
        var offset = prefixLength
        for (index, character) in changed.enumerated() {
            let length = String(character).utf16.count
            if inserted.contains(index) {
                append(NSRange(location: offset, length: length), to: &ranges)
            }
            offset += length
        }
        return ranges
    }

    /// Elements absent from the other side cannot match. Removing them before the
    /// exact diff keeps large replacements cheap without marking unchanged text.
    private static func changedOffsets<Element: Hashable>(before: [Element], after: [Element]) -> (removed: Set<Int>, inserted: Set<Int>) {
        let oldValues = Set(before), newValues = Set(after)
        let oldCandidates = before.indices.filter { newValues.contains(before[$0]) }
        let newCandidates = after.indices.filter { oldValues.contains(after[$0]) }
        var removed = Set(before.indices).subtracting(oldCandidates)
        var inserted = Set(after.indices).subtracting(newCandidates)
        let difference = newCandidates.map { after[$0] }.difference(from: oldCandidates.map { before[$0] })
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removed.insert(oldCandidates[offset])
            case let .insert(offset, _, _): inserted.insert(newCandidates[offset])
            }
        }
        return (removed, inserted)
    }

    private static func append(_ range: NSRange, to ranges: inout [NSRange]) {
        if let last = ranges.last, NSMaxRange(last) == range.location {
            ranges[ranges.count - 1].length += range.length
        } else {
            ranges.append(range)
        }
    }
}
