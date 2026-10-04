import Foundation

public enum AssistantPurpose: String, CaseIterable, Identifiable, Codable, Sendable {
    case proofreading = "校正"
    case impressions = "感想"
    case advice = "アドバイス"
    public var id: String {
        rawValue
    }

    public var label: String {
        self == .advice ? "チャット" : rawValue
    }

    public var requestInstruction: String {
        switch self {
        case .proofreading: "今回の用途は校正です。"
        case .impressions: "今回の用途は読者としての感想です。校正・添削・書き換えや修正一覧は返さず、読んで感じたことを本文の根拠とともにMarkdownで述べてください。"
        case .advice: "作者の質問に合わせて日本語で答えてください。"
        }
    }

    public var defaultPrompt: String {
        switch self {
        case .proofreading: "日本語小説を校正してください。意味や語り口を保ち、問題のない箇所を無理に変えないでください。"
        case .impressions:
            """
            あなたはこの作品を楽しみに読んでいる熱心な読者です。作者が「書いてよかった」「続きを書きたい」と思えるような感想を、友人に話すような自然な口語で書いてください。

            書き方：
            - まず、読み終えていちばん残った印象を1〜2文で。
            - 心に残った場面を2〜4つ挙げ、1文以内の短い引用と、なぜ良かったのか（笑えた・ぐっときた・驚いた・キャラが可愛い等）を具体的に。
            - 好きになった登場人物とその理由を、台詞や行動を根拠に。
            - 「この先こうなりそう」「ここが気になる」という予想や期待を1〜3つ。伏線らしい描写に気づいたら触れる。
            - 引っかかった点は最大2つまで、読者として感じたことだけを短く。直し方や書き換え案は書かない。
            - 全体で600〜1,200字程度。

            避けること：校正・添削・書き換え案・点数評価／本文に根拠のない「素晴らしい」「引き込まれる」のような褒め言葉／あらすじの要約だけで終わること／本文にない展開を事実のように書くこと。
            """
        case .advice:
            """
            あなたは作者と一緒に小説を書く相棒です。
            - 聞かれたことに答えてください。長さは質問に合わせ、短い質問には短く答えます。
            - 頼まれていない講評や改善案の列挙はしないでください。
            - 依頼があいまいなときは、推測で長く答えず、確認の質問を1つだけしてください。
            - 本文や設定に根拠を置き、作者の文体と登場人物の口調・設定を尊重してください。
            - 続きや台詞を書くときは作者の文体に合わせ、提案であることがわかるように示してください。
            """
        }
    }
}

public enum AssistantError: LocalizedError {
    case incompleteOutput, filteredOutput, unfinishedOutput, apiFailure
    case invalidConfiguration, emptyContent, tooLarge, chatContextTooLarge, missingKey, credentialFailure, invalidResponse, http(Int), composing
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "設定でHTTPSのAPI URLとモデル名を入力してください。"
        case .emptyContent: "送信する本文がありません。"
        case .tooLarge: "本文が長すぎます。1話25万文字・1MB以内で利用してください。"
        case .chatContextTooLarge: "送る範囲が大きすぎます。話や章の選択を減らして、もう一度送信してください。"
        case .missingKey: "設定でこのAPI URLのAPIキーを保存してください。"
        case .credentialFailure: "APIキーをKeychainから読み書きできませんでした。"
        case .incompleteOutput: "AIの回答が出力上限に達し、途中で止まりました。対象の本文を短くして再試行してください。"
        case .filteredOutput: "AI提供元の制限により、回答を完了できませんでした。"
        case .unfinishedOutput: "AIの回答が完了していません。時間をおいて再試行してください。"
        case .apiFailure: "AI提供元でエラーが発生しました。時間をおいて再送してください。"
        case .invalidResponse: "APIから読み取れる回答が返りませんでした。"
        case let .http(status): "APIへの接続に失敗しました（HTTP \(status)）。設定や利用上限を確認してください。"
        case .composing: "日本語入力を確定してから、もう一度操作してください。"
        }
    }
}

public struct AssistantProgress: Equatable, Sendable {
    public enum Phase: String, Sendable { case queued, working, receiving, elapsedOnly }
    public var phase: Phase
    public var characters: Int
    public init(phase: Phase, characters: Int = 0) {
        self.phase = phase; self.characters = characters
    }
}
