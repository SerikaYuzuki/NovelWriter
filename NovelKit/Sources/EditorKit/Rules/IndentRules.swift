import Foundation

/// 改行・鉤括弧入力時の自動インデントを判定する純粋なロジック(docs/DESIGN.md 4.5)。
///
/// AppKit / UIKit に一切依存せず、`String` と `NSRange`(UTF-16)だけを扱う。これにより
/// `MacTextAdapter`(将来的には iOS アダプタも)から切り離して単体テストできる
/// (docs/DESIGN.md 9.4)。`NSRange` ⇄ `String.Index` の変換は必ず `Range(_:in:)` /
/// `NSRange(_:in:)` を経由してこの型の内部に閉じ込め、絵文字・サロゲートペア・結合文字を
/// 含むテキストで壊れないようにする(UTF-16 オフセットの手計算はしない)。
///
/// 対象は次の2種類の入力だけである。それ以外の入力(複数文字にまたがるペーストなど)は
/// 常に `.allow` を返すので、呼び出し側でそのまま素通しできる。
///
/// - 改行1文字の挿入(`replacement == "\n"`)
/// - 鉤括弧1文字または括弧ペアの挿入(`replacement == "「"` / `"『"` / `"「」"` / `"『』"`)
public enum IndentRules {
    /// 字下げに用いる全角スペース(U+3000)。
    public static let fullWidthSpace: Character = "\u{3000}"

    /// ``action(for:in:range:)`` が返す判定結果。
    public enum Action: Equatable {
        /// 介入しない。呼び出し側は入力をそのまま通す。
        case allow
        /// `range` を `text` に置き換える。
        ///
        /// - `range`: 置換対象の範囲。呼び出し元から渡された挿入位置とは限らない
        ///   (R3 / R5 では入力位置と異なる範囲を置換する)。
        /// - `caretOffset`: 置換後、`range.location` を起点として数えたキャレット位置
        ///   (UTF-16 オフセット)。
        case replace(range: NSRange, text: String, caretOffset: Int)
    }

    /// IME確定後に適用する、本文置換またはキャレット移動の判定結果。
    public enum PostChangeAction: Equatable {
        /// 介入しない。
        case allow
        /// `range` を `text` に置き換える。
        case replace(range: NSRange, text: String, caretOffset: Int)
        /// 本文を変更せず、UTF-16位置へキャレットを移動する。
        case moveCaret(location: Int)
    }

    /// 改行1文字挿入・鉤括弧挿入それぞれに対する自動インデントを判定する。
    ///
    /// - Parameters:
    ///   - replacement: 挿入しようとしている文字列。1文字の改行・鉤括弧または
    ///     対応する括弧ペア以外は常に対象外(`.allow`)として扱う。
    ///   - text: 置換前の本文全体。
    ///   - range: 置換対象の範囲(UTF-16 の `NSRange`)。
    /// - Returns: 適用すべきアクション。対象外の入力は常に `.allow`。
    public static func action(for replacement: String, in text: String, range: NSRange) -> Action {
        switch replacement {
        case "\n":
            newlineAction(in: text, range: range)
        case "「", "『", "「」", "『』":
            bracketAction(replacement: replacement, in: text, range: range)
        default:
            .allow
        }
    }

    // MARK: - R1': 改行

    /// R1'(行の内容にかかわらず、改行後を常に字下げする)を判定する。
    private static func newlineAction(in text: String, range: NSRange) -> Action {
        guard range.length == 0, Range(range, in: text) != nil else { return .allow }

        // R1': 行の内容にかかわらず、新しい行を全角スペース1つで開始する。
        let insertion = "\n\(fullWidthSpace)"
        return .replace(range: range, text: insertion, caretOffset: insertion.utf16.count)
    }

    // MARK: - R3: 鉤括弧

    /// R3(字下げ行での鉤括弧入力と、任意位置での括弧ペア入力)を判定する。
    private static func bracketAction(replacement: String, in text: String, range: NSRange) -> Action {
        // 対象は素朴なキャレット入力のみ(選択範囲の置き換えは対象外)。
        guard range.length == 0, Range(range, in: text) != nil else { return .allow }

        let isPair = replacement == "「」" || replacement == "『』"

        if let line = lineBounds(at: range.location, in: text) {
            let lineEnd = line.nsRange.location + line.nsRange.length
            let shouldReplaceIndent = line.content.count == 1
                && line.content.first == fullWidthSpace
                && range.location == lineEnd
            if shouldReplaceIndent {
                let caretOffset = isPair ? 1 : replacement.utf16.count
                return .replace(range: line.nsRange, text: replacement, caretOffset: caretOffset)
            }
        }

        // 括弧ペアは字下げの有無や文中位置にかかわらず、キャレットをペア内へ置く。
        guard isPair else { return .allow }
        return .replace(range: range, text: replacement, caretOffset: 1)
    }

    private enum BracketPairCaretPosition {
        case inside
        case after(openingLocation: Int)
    }

    // MARK: - R5: IME確定後の鉤括弧

    /// IME確定後の字下げ解除と、括弧ペア内へのキャレット移動を判定する。
    ///
    /// `caretLocation` は鉤括弧直後、括弧ペア内、または括弧ペア直後のキャレット位置。
    /// 行頭が字下げ付き鉤括弧だけなら全角スペースを削除し、任意位置の括弧ペア直後なら
    /// 本文を変更せずキャレットをペア内へ移動する。
    public static func postChangeAction(in text: String, caretLocation: Int) -> PostChangeAction {
        guard let line = lineBounds(at: caretLocation, in: text) else { return .allow }
        let characters = Array(line.content)
        let caretOffsetInLine = caretLocation - line.nsRange.location
        let isSingleIndentedOpeningBracket = characters.count == 2
            && characters[0] == fullWidthSpace
            && (characters[1] == "「" || characters[1] == "『")
            && caretOffsetInLine == line.nsRange.length
        let isIndentedMatchingPair = characters.count == 3
            && characters[0] == fullWidthSpace
            && ((characters[1] == "「" && characters[2] == "」")
                || (characters[1] == "『" && characters[2] == "』"))
            && (caretOffsetInLine == 2 || caretOffsetInLine == line.nsRange.length)

        if isSingleIndentedOpeningBracket || isIndentedMatchingPair {
            let caretOffset = isIndentedMatchingPair
                ? 1
                : caretOffsetInLine - fullWidthSpace.utf16.count
            return .replace(
                range: NSRange(location: line.nsRange.location, length: fullWidthSpace.utf16.count),
                text: "",
                caretOffset: caretOffset
            )
        }

        guard case let .after(openingLocation) = bracketPairCaretPosition(
            in: text,
            caretLocation: caretLocation
        ) else {
            return .allow
        }
        return .moveCaret(location: openingLocation + 1)
    }

    // MARK: - 補助ロジック

    /// `location` を含む行の、行終端記号を除いた範囲と内容を返す。
    ///
    /// `NSString.lineRange(for:)` は行終端(`\n` など)を含んだ範囲を返すため、
    /// ここで終端記号を取り除いた「行の中身だけ」の範囲を作り直す。
    private static func lineBounds(at location: Int, in text: String) -> (nsRange: NSRange, content: Substring)? {
        let nsText = text as NSString
        guard location >= 0, location <= nsText.length else { return nil }

        let lineNSRange = nsText.lineRange(for: NSRange(location: location, length: 0))
        guard let lineRange = Range(lineNSRange, in: text) else { return nil }

        var content = text[lineRange]
        while let last = content.last, last.isNewline {
            content = content.dropLast()
        }

        let contentNSRange = NSRange(content.startIndex ..< content.endIndex, in: text)
        return (contentNSRange, content)
    }

    /// キャレットが対応する鉤括弧ペアの内側または直後にあるかをUTF-16範囲で判定する。
    private static func bracketPairCaretPosition(
        in text: String,
        caretLocation: Int
    ) -> BracketPairCaretPosition? {
        let nsLength = (text as NSString).length
        guard caretLocation >= 0, caretLocation <= nsLength else { return nil }

        if caretLocation >= 2 {
            let range = NSRange(location: caretLocation - 2, length: 2)
            if let pair = substring(in: text, range: range), pair == "「」" || pair == "『』" {
                return .after(openingLocation: range.location)
            }
        }

        if caretLocation >= 1, caretLocation < nsLength {
            let range = NSRange(location: caretLocation - 1, length: 2)
            if let pair = substring(in: text, range: range), pair == "「」" || pair == "『』" {
                return .inside
            }
        }

        return nil
    }

    private static func substring(in text: String, range: NSRange) -> Substring? {
        guard let stringRange = Range(range, in: text) else { return nil }
        return text[stringRange]
    }
}
