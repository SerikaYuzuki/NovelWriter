@testable import FUMINIWAIOS
import NovelCore
@testable import NovelSync
import SwiftUI
import Testing
import UIKit

@MainActor
@Suite("iOS work conflict review presentation")
struct IOSWorkConflictResolutionViewTests {
    @Test("作品journal失敗はpackage保存失敗と表示上も区別する")
    func wholeWorkJournalFailureKeepsLocalSavedTruth() {
        let status = IOSDeviceSyncStatusControl(
            saveState: .saved,
            state: .blocked,
            transferState: .localPending,
            localDurabilityState: .failed,
            hasLocalRecoveryReview: false,
            isLocalRecoveryReviewReady: true,
            usesWholeWorkSync: true,
            reviewChanges: {}
        )

        #expect(status.resolvedStatus == .syncPreparationError)
        #expect(status.resolvedStatus.accessibilityLabel == "この端末に保存済み、同期準備を再試行")

        let retryableReview = IOSDeviceSyncStatusControl(
            saveState: .saved,
            state: .needsReview,
            transferState: .localPending,
            localDurabilityState: .failed,
            hasLocalRecoveryReview: true,
            isLocalRecoveryReviewReady: true,
            usesWholeWorkSync: true,
            reviewChanges: {}
        )
        #expect(retryableReview.resolvedStatus == .needsReview)
    }

    @Test("作品全体の同期領域と3つの選択元を保持する")
    func presentationCoversWholeWork() {
        let presentation = makePresentation()

        #expect(presentation.fields.map(\.title) == [
            "作品タイトル",
            "あらすじ",
            "章構成",
            "話構成",
            "本文",
            "話メモ",
            "登場人物",
            "プロット",
            "伏線",
            "世界観"
        ])
        #expect(presentation.local.summary(for: .title)?.detail == "『春の庭』へ変更")
        #expect(presentation.remote.summary(for: .chapters)?.requiresChoice == true)
        #expect(presentation.proposed?.summary(for: .worldNotes)?.detail == "両方の変更を統合")
        #expect(Set([
            IOSWorkConflictReviewChoice.keepLocal,
            .keepRemote,
            .useProposed
        ]).count == 3)
    }

    @Test("狭いiPhone幅の横比較はEditorを変更せず描画できる")
    func narrowReviewRendersWithoutMutatingEditor() async {
        var selectedChoices: [IOSWorkConflictReviewChoice] = []
        var postponed = false
        let host = UIHostingController(
            rootView: IOSWorkConflictResolutionView(
                presentation: makePresentation(),
                isApplying: false,
                choose: { selectedChoices.append($0) },
                reviewLater: { postponed = true }
            )
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        host.view.frame = window.bounds
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        for _ in 0 ..< 8 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            await Task.yield()
        }

        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        #expect(image.size.width == 390)
        #expect(image.size.height == 844)
        #expect(host.view.window === window)
        #expect(selectedChoices.isEmpty)
        #expect(postponed == false)
    }

    @Test("Domainの3版と競合箇所を比較表示へ変換する")
    func adaptsDomainReview() throws {
        let workID = SyncWorkID()
        let replicaID = SyncReplicaID()
        let sessionID = SyncEditSessionID()
        let branchID = SyncBranchID()
        let baseDocument = NovelDocument.newDocument(title: "春の庭")
        let base = try WorkRevision(
            workID: workID,
            parentRevisionIDs: [],
            branchID: branchID,
            authorReplicaID: replicaID,
            authorSessionID: sessionID,
            snapshot: WorkSnapshot(document: baseDocument),
            clientCreatedAt: Date(timeIntervalSince1970: 1)
        )
        var localDocument = baseDocument
        localDocument.title = "春の庭・改"
        var remoteDocument = baseDocument
        remoteDocument.title = "夏の庭"
        let local = try WorkRevision(
            workID: workID,
            parentRevisionIDs: [base.revisionID],
            branchID: branchID,
            authorReplicaID: replicaID,
            authorSessionID: sessionID,
            snapshot: WorkSnapshot(document: localDocument),
            clientCreatedAt: Date(timeIntervalSince1970: 2)
        )
        let remote = try WorkRevision(
            workID: workID,
            parentRevisionIDs: [base.revisionID],
            branchID: SyncBranchID(),
            authorReplicaID: SyncReplicaID(),
            authorSessionID: SyncEditSessionID(),
            snapshot: WorkSnapshot(document: remoteDocument),
            clientCreatedAt: Date(timeIntervalSince1970: 3)
        )
        let conflict = WorkFieldConflict(
            path: "document.title",
            entityKind: .document,
            entityID: nil,
            field: "title",
            reason: .sameFieldChanged,
            baseValue: baseDocument.title,
            localValue: localDocument.title,
            remoteValue: remoteDocument.title,
            proposedValue: localDocument.title
        )
        let review = try WorkConflictReview(
            base: base,
            local: local,
            remote: remote,
            proposedSnapshot: local.snapshot,
            conflicts: [conflict]
        )

        let presentation = IOSWorkConflictReviewPresentation(review: review)

        #expect(presentation.workTitle == "春の庭・改")
        #expect(presentation.local.summary(for: .title)?.detail == "「春の庭・改」")
        #expect(presentation.remote.summary(for: .title)?.detail == "「夏の庭」")
        #expect(presentation.local.summary(for: .title)?.requiresChoice == true)
        #expect(presentation.fields.contains(.worldNotes))

        let unknownAncestry = try WorkConflictReview(
            base: nil,
            local: local,
            remote: remote,
            proposedSnapshot: local.snapshot,
            conflicts: [
                WorkFieldConflict(
                    path: "document.$ancestry",
                    entityKind: .document,
                    entityID: nil,
                    field: "$ancestry",
                    reason: .commonAncestorUnknown,
                    baseValue: nil,
                    localValue: local.revisionID.rawValue.uuidString,
                    remoteValue: remote.revisionID.rawValue.uuidString,
                    proposedValue: nil
                )
            ]
        )
        let unknownPresentation = IOSWorkConflictReviewPresentation(review: unknownAncestry)
        let localChoices = unknownPresentation.local.changes.filter(\.requiresChoice).count
        let remoteChoices = unknownPresentation.remote.changes.filter(\.requiresChoice).count
        let proposedChoices = unknownPresentation.proposed?.changes.filter(\.requiresChoice).count
        #expect(localChoices == IOSWorkConflictField.allCases.count)
        #expect(remoteChoices == IOSWorkConflictField.allCases.count)
        #expect(proposedChoices == IOSWorkConflictField.allCases.count)
    }

    @Test("先頭が同じ複数話でも各版の本文を末尾まで比較できる")
    func fullComparisonKeepsExactMultipleEpisodeBodies() throws {
        let values = try makeLongBodyReview()
        let presentation = IOSWorkConflictReviewPresentation(review: values.review)
        let local = try #require(presentation.local.detail(for: .episodeBodies))
        let remote = try #require(presentation.remote.detail(for: .episodeBodies))
        let proposed = try #require(presentation.proposed?.detail(for: .episodeBodies))

        #expect(local.blocks.map(\.content) == values.localBodies)
        #expect(remote.blocks.map(\.content) == values.remoteBodies)
        #expect(proposed.blocks.map(\.content) == values.localBodies)
        #expect(local.blocks.count == 2)
        #expect(remote.blocks.count == 2)
        #expect(presentation.detailFields.contains(.episodeBodies))
        #expect(local.blocks[0].content.hasSuffix("iPhone末尾A"))
        #expect(remote.blocks[0].content.hasSuffix("iCloud末尾A"))
    }

    @Test("統合予算を超えた版は全領域を未確定として表示する")
    func mergeBudgetRequiresChoiceForEveryField() throws {
        let values = try makeLongBodyReview()
        let review = try WorkConflictReview(
            base: values.review.base,
            local: values.review.local,
            remote: values.review.remote,
            proposedSnapshot: values.review.proposedSnapshot,
            conflicts: [
                WorkFieldConflict(
                    path: "document.$mergeBudget",
                    entityKind: .document,
                    entityID: nil,
                    field: "$mergeBudget",
                    reason: .mergeBudgetExceeded,
                    baseValue: nil,
                    localValue: nil,
                    remoteValue: nil,
                    proposedValue: nil
                )
            ]
        )
        let presentation = IOSWorkConflictReviewPresentation(review: review)

        #expect(presentation.local.changes.filter(\.requiresChoice).count == IOSWorkConflictField.allCases.count)
        #expect(presentation.remote.changes.filter(\.requiresChoice).count == IOSWorkConflictField.allCases.count)
        #expect(presentation.proposed?.changes.filter(\.requiresChoice).count == IOSWorkConflictField.allCases.count)
    }

    @Test("端末内復旧の各版をVoiceOverでも保存元どおりに案内する")
    func localRecoveryLabelsMatchStoredSources() throws {
        let values = try makeLongBodyReview()
        let materialized = try #require(values.review.base)
        let stagedOnly = IOSWorkLocalRecoveryPresentation(review: WorkLocalRecoveryReview(
            materializedRevision: materialized,
            stagedLocalRevision: values.review.local,
            pendingRemoteMaterialization: nil,
            observedPackageSnapshot: materialized.snapshot
        ))
        #expect(stagedOnly.remoteSource == .stagedLocal)
        #expect(stagedOnly.presentation.remotePanelTitle == "保存途中の端末内版")
        #expect(stagedOnly.presentation.remoteActionTitle == "保存途中の端末内版を採用")
        #expect(!stagedOnly.presentation.remoteActionHint.contains("iCloud"))
        #expect(!stagedOnly.presentation.comparisonAccessibilityHint.contains("iCloud"))

        let pending = WorkPendingMaterialization(
            kind: .remoteFastForward,
            sourceLocalRevisionID: values.review.local.revisionID,
            revision: values.review.remote
        )
        let pendingOnly = IOSWorkLocalRecoveryPresentation(review: WorkLocalRecoveryReview(
            materializedRevision: materialized,
            stagedLocalRevision: nil,
            pendingRemoteMaterialization: pending,
            observedPackageSnapshot: materialized.snapshot
        ))
        #expect(pendingOnly.remoteSource == .pendingRemote)
        #expect(pendingOnly.presentation.remotePanelTitle == "iCloudから取得した統合待ち版")
        #expect(pendingOnly.presentation.remoteActionHint.contains("iCloud"))

        let both = IOSWorkLocalRecoveryPresentation(review: WorkLocalRecoveryReview(
            materializedRevision: materialized,
            stagedLocalRevision: values.review.local,
            pendingRemoteMaterialization: pending,
            observedPackageSnapshot: materialized.snapshot
        ))
        #expect(both.remoteSource == .stagedLocal)
        #expect(both.proposedSource == .pendingRemote)
        #expect(both.presentation.remotePanelTitle == "保存途中の端末内版")
        #expect(both.presentation.proposedPanelTitle == "iCloudから取得した統合待ち版")
        #expect(both.presentation.proposedActionHint.contains("iCloud"))
    }

    private func makePresentation() -> IOSWorkConflictReviewPresentation {
        IOSWorkConflictReviewPresentation(
            workTitle: "春の庭",
            local: IOSWorkConflictRevisionPresentation(
                id: "local-r12",
                sourceDescription: "このiPhoneで保存",
                savedDescription: "オフラインで編集した版",
                changes: [
                    IOSWorkConflictFieldSummary(.title, detail: "『春の庭』へ変更"),
                    IOSWorkConflictFieldSummary(.episodes, detail: "第3話を追加"),
                    IOSWorkConflictFieldSummary(.characters, detail: "凪の設定を更新"),
                    IOSWorkConflictFieldSummary(.plotCards, detail: "カード2件を移動"),
                    IOSWorkConflictFieldSummary(.flags, detail: "伏線1件を回収"),
                    IOSWorkConflictFieldSummary(.worldNotes, detail: "街の設定を追記", requiresChoice: true)
                ]
            ),
            remote: IOSWorkConflictRevisionPresentation(
                id: "remote-r13",
                sourceDescription: "iCloudから取得",
                savedDescription: "もう一方の端末で編集した版",
                changes: [
                    IOSWorkConflictFieldSummary(.synopsis, detail: "結末の説明を更新"),
                    IOSWorkConflictFieldSummary(.chapters, detail: "第2章を移動", requiresChoice: true),
                    IOSWorkConflictFieldSummary(.episodeMemos, detail: "第1話のメモを更新"),
                    IOSWorkConflictFieldSummary(.characters, detail: "澪を追加"),
                    IOSWorkConflictFieldSummary(.worldNotes, detail: "街の設定を別内容へ変更", requiresChoice: true)
                ]
            ),
            proposed: IOSWorkConflictRevisionPresentation(
                id: "draft-r14",
                sourceDescription: "確認用下書き",
                savedDescription: "安全に統合できた変更を反映",
                changes: [
                    IOSWorkConflictFieldSummary(.title, detail: "このiPhoneの変更を保持"),
                    IOSWorkConflictFieldSummary(.synopsis, detail: "iCloudの変更を保持"),
                    IOSWorkConflictFieldSummary(.chapters, detail: "選択が必要", requiresChoice: true),
                    IOSWorkConflictFieldSummary(.episodes, detail: "第3話を追加"),
                    IOSWorkConflictFieldSummary(.characters, detail: "両方の変更を統合"),
                    IOSWorkConflictFieldSummary(.plotCards, detail: "このiPhoneの変更を保持"),
                    IOSWorkConflictFieldSummary(.flags, detail: "このiPhoneの変更を保持"),
                    IOSWorkConflictFieldSummary(.worldNotes, detail: "両方の変更を統合", requiresChoice: true)
                ]
            )
        )
    }

    private func makeLongBodyReview() throws -> (
        review: WorkConflictReview,
        localBodies: [String],
        remoteBodies: [String]
    ) {
        let common = String(repeating: "共通部分", count: 30)
        let firstID = EpisodeID()
        let secondID = EpisodeID()
        let chapter = Chapter(
            title: "比較章",
            episodes: [
                Episode(id: firstID, title: "第一話", content: common + "基準A"),
                Episode(id: secondID, title: "第二話", content: common + "基準B")
            ]
        )
        let baseDocument = NovelDocument(title: "全文比較", chapters: [chapter])
        var localDocument = baseDocument
        localDocument.chapters[0].episodes[0].content = common + "iPhone末尾A"
        localDocument.chapters[0].episodes[1].content = common + "iPhone末尾B"
        var remoteDocument = baseDocument
        remoteDocument.chapters[0].episodes[0].content = common + "iCloud末尾A"
        remoteDocument.chapters[0].episodes[1].content = common + "iCloud末尾B"
        let workID = SyncWorkID()
        let base = try WorkRevision(
            workID: workID,
            parentRevisionIDs: [],
            branchID: SyncBranchID(),
            authorReplicaID: SyncReplicaID(),
            authorSessionID: SyncEditSessionID(),
            snapshot: WorkSnapshot(document: baseDocument),
            clientCreatedAt: Date(timeIntervalSince1970: 1)
        )
        let local = try WorkRevision(
            workID: workID,
            parentRevisionIDs: [base.revisionID],
            branchID: SyncBranchID(),
            authorReplicaID: SyncReplicaID(),
            authorSessionID: SyncEditSessionID(),
            snapshot: WorkSnapshot(document: localDocument),
            clientCreatedAt: Date(timeIntervalSince1970: 2)
        )
        let remote = try WorkRevision(
            workID: workID,
            parentRevisionIDs: [base.revisionID],
            branchID: SyncBranchID(),
            authorReplicaID: SyncReplicaID(),
            authorSessionID: SyncEditSessionID(),
            snapshot: WorkSnapshot(document: remoteDocument),
            clientCreatedAt: Date(timeIntervalSince1970: 3)
        )
        let conflicts = [firstID, secondID].enumerated().map { index, _ in
            WorkFieldConflict(
                path: "episodes.\(index).content",
                entityKind: .episode,
                entityID: nil,
                field: "content",
                reason: .textOverlap,
                baseValue: baseDocument.chapters[0].episodes[index].content,
                localValue: localDocument.chapters[0].episodes[index].content,
                remoteValue: remoteDocument.chapters[0].episodes[index].content,
                proposedValue: localDocument.chapters[0].episodes[index].content
            )
        }
        let review = try WorkConflictReview(
            base: base,
            local: local,
            remote: remote,
            proposedSnapshot: local.snapshot,
            conflicts: conflicts
        )
        return (
            review,
            localDocument.chapters[0].episodes.map(\.content),
            remoteDocument.chapters[0].episodes.map(\.content)
        )
    }
}
