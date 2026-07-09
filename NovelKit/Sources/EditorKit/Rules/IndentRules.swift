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
        ///   (R2 / R3 では行全体の空白範囲まで拡張される)。
        /// - `caretOffset`: 置換後、`range.location` を起点として数えたキャレット位置
        ///   (UTF-16 オフセット)。
        case replace(range: NSRange, text: String, caretOffset: Int)
    }

    /// 改行1文字挿入・鉤括弧挿入それぞれに対する自動インデントを判定する。
    ///
    /// - Parameters:
    ///   - replacement: 挿入しようとしている文字列。1文字の改行・鉤括弧以外は
    ///     常に対象外(`.allow`)として扱う。
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

    // MARK: - R1 / R2: 改行

    /// R1(空白以外を含む行での改行)・R2(空白のみの行での改行)を判定する。
    private static func newlineAction(in text: String, range: NSRange) -> Action {
        guard let line = lineBounds(at: range.location, in: text) else { return .allow }

        if line.content.allSatisfy(isIndentWhitespace) {
            // R2: 空白のみの行(空行も含む) → 行の空白ごと置き換えて行を空にする。
            // 新しい行は字下げしない。置換範囲は「行の空白全体」と「挿入位置」の
            // 両方を覆うように拡張する。
            let replaceRange = NSUnionRange(line.nsRange, range)
            return .replace(range: replaceRange, text: "\n", caretOffset: 1)
        }

        // R1: 空白以外を含む行 → 新しい行を全角スペース1つで開始する。
        let insertion = "\n\(fullWidthSpace)"
        return .replace(range: range, text: insertion, caretOffset: insertion.utf16.count)
    }

    // MARK: - R3: 鉤括弧

    /// R3(行が全角スペース1つだけで、キャレットが行末にあるときの鉤括弧入力)を判定する。
    private static func bracketAction(replacement: String, in text: String, range: NSRange) -> Action {
        // 対象は素朴なキャレット入力のみ(選択範囲の置き換えは対象外)。
        guard range.length == 0 else { return .allow }
        guard let line = lineBounds(at: range.location, in: text) else { return .allow }
        guard line.content.count == 1, line.content.first == fullWidthSpace else { return .allow }

        // キャレットが行末(全角スペースの直後)にあることを確認する。
        let lineEnd = line.nsRange.location + line.nsRange.length
        guard range.location == lineEnd else { return .allow }

        let caretOffset = switch replacement {
        case "「」", "『』":
            1
        default:
            replacement.utf16.count
        }
        return .replace(range: line.nsRange, text: replacement, caretOffset: caretOffset)
    }

    // MARK: - 補助ロジック

    /// 字下げ判定における「空白」かどうか(全角/半角スペース・タブのみ)。
    private static func isIndentWhitespace(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == fullWidthSpace
    }

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
}
