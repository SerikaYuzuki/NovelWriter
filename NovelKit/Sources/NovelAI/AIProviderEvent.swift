/// Providerから逐次届くevent。完了結果にも原稿mutation APIは含まれない。
public enum AIProviderEvent: Sendable, Equatable {
    case started
    case replacementDelta(String)
    case completed(AIResult)
    case failed(AIError)
}
