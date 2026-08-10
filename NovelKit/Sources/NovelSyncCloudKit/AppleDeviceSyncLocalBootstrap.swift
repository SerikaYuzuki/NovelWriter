import Foundation
import NovelSync

/// CloudKitのasync account確認より前に、永続replica identityと
/// local copyの同期済み有無を同じatomic metadata storeから確定する。
public final class AppleDeviceSyncLocalBootstrap: @unchecked Sendable {
    public let replicaID: SyncReplicaID

    let metadataStore: AppleDeviceSyncMetadataStore
    let journalFactory: AppleDeviceSyncJournalFactory
    private let initiallyBoundLocators: Set<AppleLocalDocumentLocator>

    private init(
        metadataStore: AppleDeviceSyncMetadataStore,
        journalFactory: AppleDeviceSyncJournalFactory
    ) {
        self.metadataStore = metadataStore
        self.journalFactory = journalFactory
        replicaID = metadataStore.replicaID
        initiallyBoundLocators = metadataStore.initialBoundLocators
    }

    public static func prepare(rootURL: URL) throws -> AppleDeviceSyncLocalBootstrap {
        let metadataStore = try AppleDeviceSyncMetadataStore(rootURL: rootURL)
        let journalRoot = metadataStore.rootURL.appendingPathComponent(
            AppleDeviceSyncServices.journalDirectoryName,
            isDirectory: true
        )
        return AppleDeviceSyncLocalBootstrap(
            metadataStore: metadataStore,
            journalFactory: AppleDeviceSyncJournalFactory(
                rootURL: journalRoot,
                metadataStore: metadataStore
            )
        )
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

    /// CloudKit accountの確認前／確認不能時にも、既存bindingの端末内
    /// identityとcopy専用journalだけを復元する。remote descriptorや
    /// transport authorityは一切返さない。
    public func resolveLocal(
        _ locator: AppleLocalDocumentLocator
    ) async throws -> AppleLocalResolvedWorkingCopy? {
        try await AppleLocalResolvedWorkingCopy.resolve(
            locator,
            metadataStore: metadataStore,
            journalFactory: journalFactory
        )
    }

    /// sync準備で使ったのと同じmetadata storeからruntimeを構成する。
    public func bootstrap(
        containerIdentifier: String
    ) async throws -> AppleDeviceSyncBootstrapResult {
        try await AppleDeviceSyncServices.bootstrapPrepared(
            containerIdentifier: containerIdentifier,
            metadataStore: metadataStore,
            journalFactory: journalFactory
        )
    }
}
