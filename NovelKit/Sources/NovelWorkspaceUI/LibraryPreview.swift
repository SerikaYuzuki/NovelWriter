import Foundation
import NovelSyncV2
import NovelSyncV2Application

/// Shelf-only fixtures; app test hosts decide whether a launch argument enables them.
public struct LibraryPreview {
    public let items: [SyncV2LibraryItem]
    public let importingWorkID: WorkID?
    public let importPhases: [WorkID: ImportPhase]
    public let importFailures: [WorkID: SyncV2Failure]
    public let failure: SyncV2Failure?
    public let isLoading: Bool

    public init(mode: String) {
        let importing = WorkID(UUID())
        let failed = WorkID(UUID())
        items = (mode == "states" || mode.hasPrefix("import-")) ? [
            .init(workID: WorkID(UUID()), title: "01 海辺の便り", availability: .remoteOnly, accountState: .active),
            .init(workID: importing, title: "02 季節の記録", availability: .remoteOnly, accountState: .active),
            .init(workID: failed, title: "03 雨あがりの書斎", availability: mode.hasPrefix("import-") ? .remoteOnly : .cached,
                  accountState: .active, remoteProgress: .failed(.remoteWorkDeleted)),
            .init(workID: WorkID(UUID()), title: "04 はじまりの庭", availability: .localOnly, accountState: .unbound)
        ] : []
        importingWorkID = ["states", "import-totals", "import-unknown", "import-cancel"].contains(mode) ? importing : nil
        importFailures = mode.hasPrefix("import-") ? [failed: .retryable(.lostResponse)] : [:]
        importPhases = mode.hasPrefix("import-") && mode != "import-menu" ? [
            importing: ImportPhase(receivedBytes: 8_200_000, totalBytes: mode != "import-unknown" ? 19_000_000 : nil)
        ] : [:]
        failure = mode == "offline" ? .offline : nil
        isLoading = mode == "loading"
    }
}
