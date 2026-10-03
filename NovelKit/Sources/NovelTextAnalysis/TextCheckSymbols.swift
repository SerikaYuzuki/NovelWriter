import Foundation

struct TextCheckSymbolHit {
    let rule: TextCheckRule
    let range: NSRange
}

enum TextCheckSymbols {
    static func hits(in text: String, masks: TextCheckMasks) -> [TextCheckSymbolHit] {
        let units = Array(text.utf16)
        var hits: [TextCheckSymbolHit] = []
        let closings = Set("」』）)]｝}］】〉》〕〗〙〛”’\"'".utf16)
        func add(_ rule: TextCheckRule, _ start: Int, _ length: Int) {
            let range = NSRange(location: start, length: length)
            if masks.includes(range, symbols: true) {
                hits.append(TextCheckSymbolHit(rule: rule, range: range))
            }
        }
        var position = 0
        while position < units.count {
            if Task.isCancelled {
                return []
            }
            let unit = units[position]
            if [0x2026, 0x2015, 0xFF01, 0xFF1F, 0x3002, 0x3001].contains(unit) {
                var end = position + 1
                while end < units.count && (units[end] == unit ||
                    ((unit == 0xFF01 || unit == 0xFF1F) && (units[end] == 0xFF01 || units[end] == 0xFF1F))) {
                    end += 1
                }
                if unit == 0x2026 && (end - position) % 2 == 1 {
                    add(.oddLeader, position, end - position)
                }
                if unit == 0x2015 && (end - position) % 2 == 1 {
                    add(.oddDash, position, end - position)
                }
                if unit == 0xFF01 || unit == 0xFF1F, end < units.count,
                   units[end] != 0x3000, !closings.contains(units[end]),
                   !CharacterSet.newlines.contains(UnicodeScalar(units[end]) ?? " ") {
                    add(.punctuationSpace, position, end - position)
                }
                if unit == 0x3002, end < units.count, closings.contains(units[end]) {
                    add(.periodBeforeBracket, end - 1, 1)
                }
                if unit == 0x3002 || unit == 0x3001, end - position > 1 {
                    add(.duplicatePunctuation, position, end - position)
                }
                position = end
            } else {
                if unit == 0x21 || unit == 0x3F {
                    add(.halfWidthPunctuation, position, 1)
                }
                position += 1
            }
        }
        // IndentRulesの全角スペースと鉤括弧の字下げ解除を維持し、その他の開き括弧も除外。
        let openings = Set("「『（([｛{［【〈《〔〖〘〚“‘\"'".utf16)
        let nsText = text as NSString
        var start = 0
        while start < nsText.length {
            let range = nsText.lineRange(for: NSRange(location: start, length: 0))
            let line = nsText.substring(with: range)
            if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               units[start] != 0x3000, !openings.contains(units[start]), !masks.dialogue[start] {
                let first = nsText.rangeOfComposedCharacterSequence(at: start)
                add(.indentation, first.location, first.length)
            }
            start = NSMaxRange(range)
        }
        return hits
    }
}
