import NovelSync
import SwiftUI

private struct IOSEditorLegacySyncSheetsModifier: ViewModifier {
    @Bindable var store: IOSDocumentStore
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        presented(content)
            .modifier(
                IOSEditorLegacySyncDismissal(
                    hasLegacyReview: hasLegacyReview,
                    isPresented: $isPresented
                )
            )
    }

    private func presented(_ content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            IOSEditorLegacySyncSheetHost(
                store: store,
                isPresented: $isPresented
            )
        }
    }

    private var hasLegacyReview: Bool {
        store.workSyncLocalRecoveryReview != nil
            || store.workSyncConflictReview != nil
            || store.deviceSyncConflict != nil
            || store.deviceSyncLocalRecoveryReview != nil
    }
}

private struct IOSEditorLegacySyncDismissal: ViewModifier {
    let hasLegacyReview: Bool
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.onChange(of: hasLegacyReview) { _, hasReview in
            if !hasReview {
                isPresented = false
            }
        }
    }
}

private struct IOSEditorLegacySyncSheetHost: View {
    @Bindable var store: IOSDocumentStore
    @Binding var isPresented: Bool

    var body: some View {
        switch currentSheet {
        case let .workLocalRecovery(recovery):
            workLocalRecovery(recovery)
        case let .workConflict(review):
            workConflict(review)
        case let .episodeConflict(conflict):
            episodeConflict(conflict)
        case let .episodeRecovery(review, content):
            episodeRecovery(review, currentContent: content)
        case .empty:
            EmptyView()
        }
    }

    private enum SheetKind {
        case workLocalRecovery(WorkLocalRecoveryReview)
        case workConflict(WorkConflictReview)
        case episodeConflict(EpisodeConflict)
        case episodeRecovery(IOSDeviceSyncLocalRecoveryReview, String)
        case empty
    }

    private var currentSheet: SheetKind {
        if let recovery = store.workSyncLocalRecoveryReview {
            return .workLocalRecovery(recovery)
        }
        if let review = store.workSyncConflictReview {
            return .workConflict(review)
        }
        if let conflict = store.deviceSyncConflict {
            return .episodeConflict(conflict)
        }
        if let review = store.deviceSyncLocalRecoveryReview,
           let currentContent = store.selectedEpisode?.content {
            return .episodeRecovery(review, currentContent)
        }
        return .empty
    }

    private func workLocalRecovery(_ recovery: WorkLocalRecoveryReview) -> some View {
        let adapter = IOSWorkLocalRecoveryPresentation(review: recovery)
        return IOSWorkConflictResolutionView(
            presentation: adapter.presentation,
            isApplying: store.workSyncIsApplyingConflict,
            mode: .localRecovery
        ) { choice in
            Task {
                await store.resolveWorkSyncLocalRecovery(
                    using: choice,
                    expectedReview: recovery
                )
            }
        } reviewLater: {
            isPresented = false
        }
        .id("local-\(adapter.presentation.local.id)")
    }

    private func workConflict(_ review: WorkConflictReview) -> some View {
        IOSWorkConflictResolutionView(
            presentation: IOSWorkConflictReviewPresentation(review: review),
            isApplying: store.workSyncIsApplyingConflict
        ) { choice in
            Task {
                await store.resolveWorkSyncConflict(
                    using: choice,
                    expectedReview: review
                )
            }
        } reviewLater: {
            isPresented = false
        }
        .id(review.id)
    }

    private func episodeConflict(_ conflict: EpisodeConflict) -> some View {
        IOSDeviceSyncConflictResolutionView(
            conflict: conflict,
            state: store.deviceSyncState,
            recoveredContent: store.pendingDeviceSyncConflictResolution.flatMap {
                $0.conflict == conflict ? $0.content : nil
            }
        ) { choice in
            Task {
                await store.resolveDeviceSyncConflict(
                    using: choice,
                    expectedConflict: conflict
                )
            }
        }
        .id(conflict)
    }

    private func episodeRecovery(
        _ review: IOSDeviceSyncLocalRecoveryReview,
        currentContent: String
    ) -> some View {
        IOSDeviceSyncLocalRecoveryReviewView(
            review: review,
            currentContent: currentContent
        ) { choice in
            Task {
                await store.resolveDeviceSyncLocalRecovery(
                    using: choice,
                    expectedReview: review
                )
            }
        }
        .id(review)
    }
}

extension View {
    func iosEditorLegacySyncSheets(
        store: IOSDocumentStore,
        isPresented: Binding<Bool>
    ) -> some View {
        modifier(
            IOSEditorLegacySyncSheetsModifier(store: store, isPresented: isPresented)
        )
    }
}
