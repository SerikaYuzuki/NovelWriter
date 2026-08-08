import Foundation

/// Providerが報告する利用量。inputの不明値は`nil`、outputは完了検証で必須とする。
public struct AIUsage: Sendable, Equatable {
    public let inputTokens: Int?
    public let outputTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// 校正提案の結果。原稿を書き換えるAPIは持たず、呼び出し側が確認して扱う値だけを返す。
public struct AIResult: Sendable, Equatable {
    public let replacement: String
    public let summary: String
    public let warnings: [String]
    public let usage: AIUsage

    public init(
        replacement: String,
        summary: String,
        warnings: [String] = [],
        usage: AIUsage = AIUsage()
    ) {
        self.replacement = replacement
        self.summary = summary
        self.warnings = warnings
        self.usage = usage
    }

    /// output budgetで数える、provider由来の全テキストの文字数。
    public var outputCharacterCount: Int {
        var total = addingSaturating(replacement.count, summary.count)
        for warning in warnings {
            total = addingSaturating(total, warning.count)
        }
        return total
    }

    /// provider由来の全テキストをUTF-8へ変換したbyte数。
    public var outputUTF8ByteCount: Int {
        var total = addingSaturating(replacement.utf8.count, summary.utf8.count)
        for warning in warnings {
            total = addingSaturating(total, warning.utf8.count)
        }
        return total
    }

    private func addingSaturating(_ lhs: Int, _ rhs: Int) -> Int {
        let addition = lhs.addingReportingOverflow(rhs)
        return addition.overflow ? Int.max : addition.partialValue
    }
}
