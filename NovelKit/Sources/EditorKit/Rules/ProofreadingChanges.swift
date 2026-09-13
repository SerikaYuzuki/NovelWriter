import Foundation

/// Character boundaries preserve composed Japanese text and emoji; ranges use native UTF-16 offsets.
public enum ProofreadingChanges {
    /// Unchanged edges are excluded before diffing. Large rewrites highlight the
    /// changed block, bounding presentation work without altering manuscript text.
    public static func insertedRanges(original: String, revised: String) -> [NSRange] {
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
        guard oldEnd - start + newEnd - start <= 1024 else {
            return [NSRange(location: prefixLength, length: changed.reduce(0) { $0 + String($1).utf16.count })]
        }
        let inserted = Set(changed.difference(from: before[start ..< oldEnd]).compactMap { change -> Int? in
            if case let .insert(offset, _, _) = change {
                return offset
            }
            return nil
        })
        var ranges: [NSRange] = []
        var offset = prefixLength
        for (index, character) in changed.enumerated() {
            let length = String(character).utf16.count
            if inserted.contains(index) {
                if let last = ranges.last, NSMaxRange(last) == offset {
                    ranges[ranges.count - 1].length += length
                } else {
                    ranges.append(NSRange(location: offset, length: length))
                }
            }
            offset += length
        }
        return ranges
    }
}
