import Foundation

/// Providerを安定して識別する値。具体adapterをNovelAIへ依存させずに追加できる。
public struct AIProviderID: RawRepresentable, Sendable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let codex = Self(rawValue: "codex")
    public static let openRouter = Self(rawValue: "openrouter")
}

/// Providerによるsession保存・学習利用について、確認できた根拠を含む状態。
public enum AIProviderDataUseStatus: String, Sendable, Hashable {
    case providerReportedNotUsed
    case providerReportedUsed
    case notVerified
}

/// Provider adapterが利用する認証方式。
public enum AIProviderAuthentication: String, Sendable, Hashable {
    case apiKey
    case account
    case none
    case unknown
}

/// UIや呼び出し側が事前に判定できるprovider能力。
public enum AIProviderCapability: String, Sendable, Hashable {
    /// 非同期event streamを提供する能力。部分的な置換本文の到着は保証しない。
    case streaming
    case cancellation
    case usageReporting
    case sessionResume
}

/// 送信前previewへ固定するprovider情報。
///
/// `destination` は利用者へ表示する送信先名であり、URLやfile pathではない。
public struct AIProviderDescriptor: Sendable, Equatable {
    public let id: AIProviderID
    public let displayName: String
    public let destination: String
    public let modelID: String
    public let modelDisplayName: String
    public let sessionStorage: AIProviderDataUseStatus
    public let trainingUse: AIProviderDataUseStatus
    public let authentication: AIProviderAuthentication
    public let capabilities: Set<AIProviderCapability>

    public init(
        id: AIProviderID,
        displayName: String,
        destination: String,
        modelID: String,
        modelDisplayName: String,
        sessionStorage: AIProviderDataUseStatus,
        trainingUse: AIProviderDataUseStatus,
        authentication: AIProviderAuthentication,
        capabilities: Set<AIProviderCapability>
    ) {
        self.id = id
        self.displayName = displayName
        self.destination = destination
        self.modelID = modelID
        self.modelDisplayName = modelDisplayName
        self.sessionStorage = sessionStorage
        self.trainingUse = trainingUse
        self.authentication = authentication
        self.capabilities = capabilities
    }
}
