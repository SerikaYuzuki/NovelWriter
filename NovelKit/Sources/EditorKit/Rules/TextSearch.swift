import Foundation

/// 検索ジャンプの方向。
public enum TextSearchDirection: Sendable {
    case forward
    case backward
}

/// エディタ内検索の純粋ロジック。
///
/// AppKit / UIKit に依存せず、`String` と UTF-16 単位の `NSRange` だけを扱う。
/// UI 側はこの結果を ``EditorSelectionRequest`` として `EditorView` に渡す。
public enum TextSearch {
    /// 指定した位置から検索し、見つかった範囲を UTF-16 単位で返す。
    ///
    /// - Parameters:
    ///   - query: 検索語。空文字列なら `nil`。
    ///   - text: 検索対象の本文。
    ///   - location: 検索開始位置(UTF-16)。範囲外なら本文末尾/先頭へ丸める。
    ///   - direction: 検索方向。
    ///   - wraps: 見つからなかった場合に反対端へ回り込むか。
    /// - Returns: 見つかった範囲。見つからない場合は `nil`。
    public static func find(
        query: String,
        in text: String,
        from location: Int,
        direction: TextSearchDirection = .forward,
        wraps: Bool = true
    ) -> NSRange? {
        guard !query.isEmpty else { return nil }

        let nsText = text as NSString
        let textLength = nsText.length
        let clampedLocation = min(max(location, 0), textLength)

        switch direction {
        case .forward:
            return findForward(query: query, in: nsText, from: clampedLocation, wraps: wraps)
        case .backward:
            return findBackward(query: query, in: nsText, from: clampedLocation, wraps: wraps)
        }
    }

    private static func findForward(query: String, in text: NSString, from location: Int, wraps: Bool) -> NSRange? {
        let tailRange = NSRange(location: location, length: text.length - location)
        let tailMatch = text.range(of: query, options: [.caseInsensitive], range: tailRange)
        if tailMatch.location != NSNotFound {
            return tailMatch
        }

        guard wraps, location > 0 else { return nil }
        let headRange = NSRange(location: 0, length: location)
        let headMatch = text.range(of: query, options: [.caseInsensitive], range: headRange)
        return headMatch.location == NSNotFound ? nil : headMatch
    }

    private static func findBackward(query: String, in text: NSString, from location: Int, wraps: Bool) -> NSRange? {
        let headRange = NSRange(location: 0, length: location)
        let headMatch = text.range(of: query, options: [.caseInsensitive, .backwards], range: headRange)
        if headMatch.location != NSNotFound {
            return headMatch
        }

        guard wraps, location < text.length else { return nil }
        let tailRange = NSRange(location: location, length: text.length - location)
        let tailMatch = text.range(of: query, options: [.caseInsensitive, .backwards], range: tailRange)
        return tailMatch.location == NSNotFound ? nil : tailMatch
    }
}
