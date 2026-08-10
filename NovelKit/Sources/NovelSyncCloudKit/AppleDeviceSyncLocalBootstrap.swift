import Foundation
import NovelSync

/// CloudKitのasync account確認より前に、永続replica identityと
/// local copyの同期済み有無を同じatomic metadata storeから確定する。
public final class AppleDeviceSyncLocalBootstrap: @unchecked Sendable {
    public let replicaID: SyncReplicaID

    let metadataStore: AppleDeviceSyncMetadataStore
    private let initiallyBoundLocators: Set<AppleLocalDocumentLocator>

    private init(metadataStore: AppleDeviceSyncMetadataStore) {
        self.metadataStore = metadataStore
        replicaID = metadataStore.replicaID
        initiallyBoundLocators = metadataStore.initialBoundLocators
    }

    public static func prepare(rootURL: URL) throws -> AppleDeviceSyncLocalBootstrap {
        let metadataStore = try AppleDeviceSyncMetadataStore(rootURL: rootURL)
        return AppleDeviceSyncLocalBootstrap(metadataStore: metadataStore)
    }

    /// account authority未確認の間、過去にbindされたcopyは必ずblockedとし、
    /// unbound copyだけをlocal-only編集へ進められる。
    public func localStatus(
        for locator: AppleLocalDocumentLocator
    ) -> AppleDeviceSyncLocalBindingStatus {
        initiallyBoundLocators.contains(locator)
            ? .boundAndBlocked(.accountUnavailable)
            : .unbound
    }

    /// sync準備で使ったのと同じmetadata storeからruntimeを構成する。
    public func bootstrap(
        containerIdentifier: String
    ) async throws -> AppleDeviceSyncBootstrapResult {
        try await AppleDeviceSyncServices.bootstrapPrepared(
            containerIdentifier: containerIdentifier,
            metadataStore: metadataStore
        )
    }
}
