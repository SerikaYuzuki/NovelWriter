import AppKit
@testable import FUMINIWA
import NovelCore
@testable import NovelSync
import SwiftUI
import Testing

@MainActor
@Suite("Work conflict review presentation")
struct WorkConflictResolutionViewTests {
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
            WorkConflictReviewChoice.keepLocal,
            .keepRemote,
            .useProposed
        ]).count == 3)
    }

    @Test("Macの3列比較はEditorを変更せずlayoutできる")
    func threeColumnReviewLaysOutWithoutMutatingEditor() {
        var selectedChoices: [WorkConflictReviewChoice] = []
        var postponed = false
        let host = NSHostingView(rootView: WorkConflictResolutionView(
            presentation: makePresentation(),
            isApplying: false,
            choose: { selectedChoices.append($0) },
            reviewLater: { postponed = true }
        ))
        host.frame = NSRect(x: 0, y: 0, width: 1120, height: 760)
        host.layoutSubtreeIfNeeded()

        #expect(host.fittingSize.width >= 960)
        #expect(host.fittingSize.height >= 640)
        #expect(host.isHidden == false)
        #expect(selectedChoices.isEmpty)
        #expect(postponed == false)
    }

    @Test("先頭が同じ複数話でも各版の本文を末尾まで比較できる")
    func fullComparisonKeepsExactMultipleEpisodeBodies() throws {
        let values = try makeLongBodyReview()
        let presentation = WorkConflictPresentationAdapter.make(review: values.review)
        let local = try #require(presentation.local.detail(for: .episodeBodies))
        let remote = try #require(presentation.remote.detail(for: .episodeBodies))

        #expect(local.blocks.map(\.content) == values.localBodies)
        #expect(remote.blocks.map(\.content) == values.remoteBodies)
        #expect(local.blocks.count == 2)
        #expect(remote.blocks.count == 2)
        #expect(presentation.detailFields.contains(.episodeBodies))
        #expect(local.blocks[0].content.hasSuffix("Mac末尾A"))
        #expect(remote.blocks[0].content.hasSuffix("iCloud末尾A"))
    }

    @Test("統合予算を超えた版は全領域を未確定として表示する")
    func mergeBudgetRequiresChoiceForEveryField() throws {
        let values = try makeLongBodyReview()
        let budgetConflict = WorkFieldConflict(
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
        let review = try WorkConflictReview(
            base: values.review.base,
            local: values.review.local,
            remote: values.review.remote,
            proposedSnapshot: values.review.proposedSnapshot,
            conflicts: [budgetConflict]
        )
        let presentation = WorkConflictPresentationAdapter.make(review: review)

        #expect(presentation.local.changes.filter(\.requiresChoice).count == WorkConflictField.allCases.count)
        #expect(presentation.remote.changes.filter(\.requiresChoice).count == WorkConflictField.allCases.count)
        #expect(presentation.proposed?.changes.filter(\.requiresChoice).count == WorkConflictField.allCases.count)
    }

    private func makePresentation() -> WorkConflictReviewPresentation {
        WorkConflictReviewPresentation(
            workTitle: "春の庭",
            local: WorkConflictRevisionPresentation(
                id: "local-r12",
                sourceDescription: "このMacで保存",
                savedDescription: "オフラインで編集した版",
                changes: [
                    WorkConflictFieldSummary(.title, detail: "『春の庭』へ変更"),
                    WorkConflictFieldSummary(.episodes, detail: "第3話を追加"),
                    WorkConflictFieldSummary(.characters, detail: "凪の設定を更新"),
                    WorkConflictFieldSummary(.plotCards, detail: "カード2件を移動"),
                    WorkConflictFieldSummary(.flags, detail: "伏線1件を回収"),
                    WorkConflictFieldSummary(.worldNotes, detail: "街の設定を追記", requiresChoice: true)
                ]
            ),
            remote: WorkConflictRevisionPresentation(
                id: "remote-r13",
                sourceDescription: "iCloudから取得",
                savedDescription: "もう一方の端末で編集した版",
                changes: [
                    WorkConflictFieldSummary(.synopsis, detail: "結末の説明を更新"),
                    WorkConflictFieldSummary(.chapters, detail: "第2章を移動", requiresChoice: true),
                    WorkConflictFieldSummary(.episodeMemos, detail: "第1話のメモを更新"),
                    WorkConflictFieldSummary(.characters, detail: "澪を追加"),
                    WorkConflictFieldSummary(.worldNotes, detail: "街の設定を別内容へ変更", requiresChoice: true)
                ]
            ),
            proposed: WorkConflictRevisionPresentation(
                id: "draft-r14",
                sourceDescription: "確認用下書き",
                savedDescription: "安全に統合できた変更を反映",
                changes: [
                    WorkConflictFieldSummary(.title, detail: "この端末の変更を保持"),
                    WorkConflictFieldSummary(.synopsis, detail: "iCloudの変更を保持"),
                    WorkConflictFieldSummary(.chapters, detail: "選択が必要", requiresChoice: true),
                    WorkConflictFieldSummary(.episodes, detail: "第3話を追加"),
                    WorkConflictFieldSummary(.characters, detail: "両方の変更を統合"),
                    WorkConflictFieldSummary(.plotCards, detail: "この端末の変更を保持"),
                    WorkConflictFieldSummary(.flags, detail: "この端末の変更を保持"),
                    WorkConflictFieldSummary(.worldNotes, detail: "両方の変更を統合", requiresChoice: true)
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
        localDocument.chapters[0].episodes[0].content = common + "Mac末尾A"
        localDocument.chapters[0].episodes[1].content = common + "Mac末尾B"
        var remoteDocument = baseDocument
        remoteDocument.chapters[0].episodes[0].content = common + "iCloud末尾A"
        remoteDocument.chapters[0].episodes[1].content = common + "iCloud末尾B"
        let workID = SyncWorkID()
        let branchID = SyncBranchID()
        let replicaID = SyncReplicaID()
        let sessionID = SyncEditSessionID()
        let base = try WorkRevision(
            workID: workID,
            parentRevisionIDs: [],
            branchID: branchID,
            authorReplicaID: replicaID,
            authorSessionID: sessionID,
            snapshot: WorkSnapshot(document: baseDocument),
            clientCreatedAt: Date(timeIntervalSince1970: 1)
        )
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
