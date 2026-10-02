import Foundation

/// UTF-16位置を保持したまま記法・会話の内部を除外する。
struct TextCheckMasks {
    let notation: [Bool]
    let dialogue: [Bool]
    let lexicalNotation: [Bool]
    init(_ text: String) {
        let units = Array(text.utf16)
        var notation = Array(repeating: false, count: units.count)
        let pattern = "[｜|]([^《\\r\\n]+)《[^》\\r\\n]+》"
        var lexicalNotation = notation
        if let regex = try? NSRegularExpression(pattern: pattern) {
            for match in regex.matches(in: text, range: NSRange(location: 0, length: units.count)) {
                for index in match.range.location ..< NSMaxRange(match.range) {
                    notation[index] = true; lexicalNotation[index] = true
                }
                let parent = match.range(at: 1)
                for index in parent.location ..< NSMaxRange(parent) {
                    lexicalNotation[index] = false
                }
            }
        }
        var dialogue = Array(repeating: false, count: units.count)
        var closings: [UInt16] = []
        for (index, unit) in units.enumerated() {
            if unit == 0x300C {
                closings.append(0x300D)
            }
            if unit == 0x300E {
                closings.append(0x300F)
            }
            dialogue[index] = !closings.isEmpty
            if unit == closings.last {
                closings.removeLast()
            }
        }
        self.notation = notation; self.dialogue = dialogue; self.lexicalNotation = lexicalNotation
    }

    func includes(_ range: NSRange, excludeDialogue: Bool = false, symbols: Bool = false) -> Bool {
        guard range.location >= 0, range.length > 0, NSMaxRange(range) <= notation.count else { return false }
        return (range.location ..< NSMaxRange(range)).allSatisfy {
            !(symbols ? notation[$0] : lexicalNotation[$0]) && (!excludeDialogue || !dialogue[$0])
        }
    }
}
