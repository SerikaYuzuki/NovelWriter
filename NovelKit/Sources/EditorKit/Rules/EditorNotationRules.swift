/// なろう形式のルビ・傍点を生成する純粋な規則。
///
/// 入力中の記号はescape・変換せず、そのまま本文へ挿入する。
public enum EditorNotationRules {
    public static func ruby(parentText: String, rubyText: String) -> String? {
        guard !parentText.isEmpty, !rubyText.isEmpty else { return nil }
        return "｜\(parentText)《\(rubyText)》"
    }

    public static func bouten(text: String) -> String? {
        guard !text.isEmpty else { return nil }

        var result = ""
        result.reserveCapacity(text.utf8.count * 5)
        for character in text {
            if character.isNewline || character == " " || character == "\u{3000}" || character == "\t" {
                result.append(character)
            } else {
                result += "｜\(character)《・》"
            }
        }

        return result == text ? nil : result
    }
}
