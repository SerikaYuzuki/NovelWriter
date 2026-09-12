import Foundation

/// Character boundaries preserve composed Japanese text and emoji; ranges use native UTF-16 offsets.
public enum ProofreadingChanges {
    public static func insertedRanges(original: String, revised: String) -> [NSRange] {
        let characters = Array(revised)
        let inserted = Set(characters.difference(from: Array(original)).compactMap { change -> Int? in
            if case let .insert(offset, _, _) = change {
                return offset
            }
            return nil
        })
        var ranges: [NSRange] = []
        var offset = 0
        for (index, character) in characters.enumerated() {
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
