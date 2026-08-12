import Foundation

public extension EpisodeSyncCoordinator {
    /// 同じholderならepochを維持してrenewする。他holderならread-onlyを返す。
    @discardableResult
    func claimEditingAuthority(expiresAt: Date) async throws -> EpisodeSyncState {
        await acquireRemoteControlOperation()
        defer { releaseRemoteControlOperation() }
        return try await claimEditingAuthoritySerially(expiresAt: expiresAt)
    }

    /// 現holderの有無やUX上のexpiryにかかわらずepochを必ず増やして引き継ぐ。
    @discardableResult
    func forceEditingAuthority(expiresAt: Date) async throws -> EpisodeSyncState {
        await acquireRemoteControlOperation()
        defer { releaseRemoteControlOperation() }
        _ = try await prepareForcedContinuationSerially(expiresAt: expiresAt)
        return state
    }

    /// force CAS後のexact remote headを返すが、Appのinstall ackまではpublish権を有効化しない。
    func prepareForcedContinuation(expiresAt: Date) async throws -> EpisodeAuthorityGrant {
        await acquireRemoteControlOperation()
        defer { releaseRemoteControlOperation() }
        return try await prepareForcedContinuationSerially(expiresAt: expiresAt)
    }

    /// 競合UIが表示したexact local / remote parentを保ったまま、
    /// 2-parent mergeをpublishするためだけにauthorityを取り直す。
    /// 通常のforceと分け、既存forkを現在のeditor本文で上書きさせない。
    func prepareConflictResolutionAuthority(
        expectedConflict: EpisodeConflict,
        expiresAt: Date
    ) async throws -> EpisodeAuthorityGrant {
        await acquireRemoteControlOperation()
        defer { releaseRemoteControlOperation() }
        return try await prepareConflictResolutionAuthoritySerially(
            expectedConflict: expectedConflict,
            expiresAt: expiresAt
        )
    }

    /// Appがobserved remote本文をpackage/native editorへinstallした後のack。
    @discardableResult
    func confirmObservedRemoteInstall(
        _ observation: EpisodeFenceObservation,
        installedRemoteDigest: SyncContentDigest?
    ) async throws -> EpisodeSyncState {
        await acquireRemoteControlOperation()
        defer { releaseRemoteControlOperation() }
        return try await confirmObservedRemoteInstallSerially(
            observation,
            installedRemoteDigest: installedRemoteDigest
        )
    }

    /// Appがexact remote本文をpackageとnative editorへinstallした後のack。
    @discardableResult
    func confirmAuthorityInstall(
        _ grant: EpisodeAuthorityGrant,
        installedRemoteDigest: SyncContentDigest?
    ) async throws -> EpisodeSyncState {
        await acquireRemoteControlOperation()
        defer { releaseRemoteControlOperation() }
        return try await confirmAuthorityInstallSerially(
            grant,
            installedRemoteDigest: installedRemoteDigest
        )
    }

    /// 画面/sessionが切り替わりinstallを完了しない時に、取得済みleaseだけを安全に解放する。
    @discardableResult
    func abandonAuthorityGrant(_ grant: EpisodeAuthorityGrant) async throws -> EpisodeSyncState {
        await acquireRemoteControlOperation()
        defer { releaseRemoteControlOperation() }
        return try await abandonAuthorityGrantSerially(grant)
    }

    /// live processのauthorityとremote control/headを照合し、exact snapshotを返す。
    @discardableResult
    func inspectFence() async throws -> EpisodeFenceObservation {
        await acquireRemoteControlOperation()
        defer { releaseRemoteControlOperation() }
        return try await inspectFenceSerially()
    }

    @discardableResult
    func releaseEditingAuthority() async throws -> EpisodeSyncState {
        await acquireRemoteControlOperation()
        defer { releaseRemoteControlOperation() }
        return try await releaseEditingAuthoritySerially()
    }
}
