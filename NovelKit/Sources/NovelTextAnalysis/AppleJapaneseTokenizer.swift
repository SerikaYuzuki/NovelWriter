import CoreFoundation
import Foundation

public struct JapaneseTextToken: Equatable, Sendable {
    public let text: String
    public let reading: String?
    public let range: NSRange
    public init(text: String, reading: String?, range: NSRange) {
        self.text = text; self.reading = reading; self.range = range
    }
}

/// OS辞書の分割・読みは保証しない。将来の検出器も同じUTF-16範囲を返す。
public protocol JapaneseTextTokenizing: Sendable {
    func tokens(in text: String) -> [JapaneseTextToken]
}

public struct AppleJapaneseTokenizer: JapaneseTextTokenizing {
    public init() {}
    public func tokens(in text: String) -> [JapaneseTextToken] {
        let source = text as NSString
        guard let tokenizer = CFStringTokenizerCreate(
            nil, text as CFString, CFRange(location: 0, length: source.length),
            kCFStringTokenizerUnitWord | kCFStringTokenizerAttributeLatinTranscription,
            NSLocale(localeIdentifier: "ja_JP") as CFLocale
        ) else { return [] }
        var result: [JapaneseTextToken] = []
        while CFStringTokenizerAdvanceToNextToken(tokenizer).rawValue != 0 {
            guard !Task.isCancelled else { return [] }
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let nsRange = NSRange(location: range.location, length: range.length)
            let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String
            var reading: String?
            if let latin {
                let value = NSMutableString(string: latin)
                if CFStringTransform(value, nil, kCFStringTransformLatinHiragana, false) {
                    reading = (value as String).replacingOccurrences(of: " ", with: "")
                }
            }
            result.append(JapaneseTextToken(text: source.substring(with: nsRange), reading: reading, range: nsRange))
        }
        return result
    }
}
