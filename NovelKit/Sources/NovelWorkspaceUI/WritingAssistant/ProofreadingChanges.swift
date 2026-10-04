import Foundation

public struct ProofreadingChange: Codable, Equatable, Sendable {
    public let before: String
    public let after: String
    public let reason: String
    public let check: String
    public init(before: String, after: String, reason: String, check: String) {
        self.before = before; self.after = after; self.reason = reason; self.check = check
    }
}

public struct ProofreadingChanges: Decodable, Sendable {
    public let changes: [ProofreadingChange]
    public static let outputInstruction = """
    JSONオブジェクト {"changes":[{"before":"修正前の抜粋","after":"修正後の抜粋","reason":"修正理由","check":"項目のidまたはother"}]} のみを返してください。
    beforeは送信本文contentと文字・改行・空白まで完全に一致し、本文内に1回だけ現れる短い抜粋にしてください。一意になるだけの前後の文脈を含め、afterにも変更しない文脈を保持してください。
    提案の範囲は互いに重ならないようにしてください。理由は日本語で書き、checkは該当するチェック項目のid、不明ならotherにしてください。直す箇所がなければ {"changes":[]} を返してください。参考情報は修正対象ではありません。
    """

    public struct Rejected: Sendable {
        public let change: ProofreadingChange
        public let explanation: String
    }

    public struct Application: Sendable {
        public let replacement: String
        public let accepted: [ProofreadingChange]
        public let rejected: [Rejected]
    }

    /// Match against the sent bytes, never against an already modified string.
    /// Overlap is checked for all candidates so response order cannot choose a winner.
    public func application(to text: String) throws -> Application {
        let source = text as NSString
        var located: [(Int, NSRange)] = []
        var failures: [Int: String] = [:]
        for (index, change) in changes.enumerated() {
            guard !change.before.isEmpty else { failures[index] = "修正前の抜粋が空です。"; continue }
            let range = source.range(of: change.before, options: .literal)
            guard range.location != NSNotFound else { failures[index] = "送信した本文に一致しません。"; continue }
            // Search from the next UTF-16 position, including overlapping occurrences.
            let next = range.location + 1
            let another = source.range(of: change.before, options: .literal,
                                       range: NSRange(location: next, length: source.length - next))
            guard another.location == NSNotFound else { failures[index] = "本文に複数回現れるため、場所を特定できません。"; continue }
            located.append((index, range))
        }
        let ordered = located.sorted { $0.1.location < $1.1.location }
        var furthest: (Int, NSRange)?
        for candidate in ordered {
            if let previous = furthest, candidate.1.location < NSMaxRange(previous.1) {
                failures[previous.0] = "別の提案と修正範囲が重なっています。"
                failures[candidate.0] = "別の提案と修正範囲が重なっています。"
            }
            if furthest == nil || NSMaxRange(candidate.1) > NSMaxRange(furthest!.1) {
                furthest = candidate
            }
        }
        let applicable = located.filter { failures[$0.0] == nil }
        let replacement = NSMutableString(string: text)
        for (index, range) in applicable.sorted(by: { $0.1.location > $1.1.location }) {
            replacement.replaceCharacters(in: range, with: changes[index].after)
        }
        let result = replacement as String
        guard result.count <= 250_000, result.utf8.count <= 1_000_000 else { throw AssistantError.tooLarge }
        return Application(replacement: result, accepted: applicable.map { changes[$0.0] },
                           rejected: changes.enumerated().compactMap { index, change in
                               failures[index].map { Rejected(change: change, explanation: $0) }
                           })
    }
}
