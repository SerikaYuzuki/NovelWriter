import Foundation
import NovelCore
import NovelWritingSupport

public enum ProofreadingCheck: String, CaseIterable, Identifiable, Sendable {
    case typo, grammar, readability, jpPunctuation, leaderDash, fullWidthMarks
    case periodBeforeBracket, indentation, variation, characterNames, keepDialogue, keepStyle

    public var id: String {
        rawValue
    }

    public var preservesText: Bool {
        self == .keepDialogue || self == .keepStyle
    }

    public var label: String {
        switch self {
        case .typo: "誤字・脱字・変換ミス"
        case .grammar: "文法の誤り・主語と述語のねじれ"
        case .readability: "意味が取りにくい文だけを最小限に直す"
        case .jpPunctuation: "「，．」を「、。」に統一"
        case .leaderDash: "三点リーダー・ダッシュを2個1組（……／――）に統一し「・・・」「...」も直す"
        case .fullWidthMarks: "！？を全角にし、文中では直後に全角スペース"
        case .periodBeforeBracket: "閉じ括弧直前の句点を取る（。」→」）"
        case .indentation: "地の文の段落頭を全角スペースで字下げ（会話・記号行は除く）"
        case .variation: "同じ話の中の表記ゆれを多い方に統一"
        case .characterNames: "人物名の書き間違い（登場人物名の一覧を一緒に送る）"
        case .keepDialogue: "会話文（「」『』内）の口調・くだけた表現は直さない"
        case .keepStyle: "擬音・造語・ルビ・意図的な崩しは直さない"
        }
    }

    public var instruction: String {
        switch self {
        case .typo: "誤字・脱字・変換ミスを直してください。"
        case .grammar: "文法の誤りと、主語と述語のねじれを直してください。"
        case .readability: "意味が取りにくい文だけを、意味が伝わる最小限の変更で直してください。"
        case .jpPunctuation: "句読点の「，」「．」を「、」「。」に統一してください。"
        case .leaderDash: "三点リーダーとダッシュは「……」「――」の2個1組に統一し、「・・・」「...」も「……」に直してください。"
        case .fullWidthMarks: "感嘆符と疑問符を全角の「！」「？」に統一し、文中では連続する！？の直後に全角スペースを1つ置いてください。閉じ括弧直前と行末には足さないでください。"
        case .periodBeforeBracket: "閉じ括弧（」・』）の直前にある句点を取ってください（。」→」、。』→』）。"
        case .indentation: "地の文の段落頭を全角スペース1つで字下げしてください。会話で始まる行と記号だけの行は除いてください。"
        case .variation: "同じ話の中で、同じ意味・用法の語の表記が揺れていれば、出現回数が多い表記に統一してください。同数なら変えないでください。"
        case .characterNames: "参考情報の登場人物名と読みを照合し、人物名の明らかな書き間違いだけを直してください。別名や呼び方の違いは誤りと決めつけないでください。"
        case .keepDialogue: "会話文（「」『』内）の口調やくだけた表現は直さないでください。"
        case .keepStyle: "擬音・造語・ルビ・意図的に崩した表現は直さないでください。"
        }
    }
}

/// The payload stays an opaque prompt record; unknown IDs survive editing by older clients.
public struct ProofreadingChecklist: Codable, Equatable, Sendable {
    public static let key = "校正チェック"
    public static let defaults = Self(checks: ["typo", "grammar", "readability", "jpPunctuation", "keepDialogue", "keepStyle"])
    public var checks: [String]
    public init(checks: [String]) {
        self.checks = checks
    }

    public init(selection: Set<String>) {
        let known = ProofreadingCheck.allCases.map(\.id)
        checks = known.filter { selection.contains($0) } + selection.subtracting(known).sorted()
    }

    public static func latest(_ records: [WritingEnvelope]) -> WritingEnvelope? {
        let candidates = records.filter { $0.record.kind == "prompt" && $0.record.key == key && !$0.conflicted }
        return candidates.last(where: { $0.sequence == 0 }) ?? candidates.max(by: { $0.sequence < $1.sequence })
    }

    public static func effective(common: [WritingEnvelope], work: [WritingEnvelope]) throws -> Self {
        if let record = latest(work) ?? latest(common) {
            return try record.record.decoded(Self.self)
        }
        return defaults
    }

    public var instructions: String {
        let selected = ProofreadingCheck.allCases.filter { checks.contains($0.id) }
        let review = selected.filter { !$0.preservesText }.map { "- [\($0.id)] \($0.instruction)" }
        let keep = selected.filter(\.preservesText).map { "- [\($0.id)] \($0.instruction)" }
        return "今回確認する項目:\n" + (review.isEmpty ? "- なし。修正を提案しないでください。" : review.joined(separator: "\n"))
            + "\n\n直さないもの:\n" + (keep.isEmpty ? "- 指定なし。" : keep.joined(separator: "\n"))
            + "\n選択されていない項目の修正は提案しないでください。直さないものの指定を優先してください。"
    }

    public func reference(characters: [NovelCore.Character]) -> String? {
        guard checks.contains(ProofreadingCheck.characterNames.id) else { return nil }
        return "登場人物名・読み:\n" + (characters.isEmpty ? "（登録なし）" : characters.map {
            "- 名前: \($0.name) / 読み: \($0.kana.isEmpty ? "未登録" : $0.kana)"
        }.joined(separator: "\n"))
    }
}
