import Foundation
import NovelSync

enum WorkConflictPresentationAdapter {
    static func make(review: WorkConflictReview) -> WorkConflictReviewPresentation {
        let allFieldsRequireChoice = review.base == nil || review.conflicts.contains {
            $0.reason == .mergeBudgetExceeded
        }
        let conflictedFields = allFieldsRequireChoice
            ? Set(WorkConflictField.allCases)
            : Set(review.conflicts.map(field(for:)))
        return WorkConflictReviewPresentation(
            workTitle: review.local.snapshot.title,
            local: revision(
                review.local,
                sourceDescription: "このMacで保存した版",
                base: review.base?.snapshot,
                conflicts: review.conflicts,
                conflictValue: \.localValue,
                conflictedFields: conflictedFields
            ),
            remote: revision(
                review.remote,
                sourceDescription: "iCloudから取得した版",
                base: review.base?.snapshot,
                conflicts: review.conflicts,
                conflictValue: \.remoteValue,
                conflictedFields: conflictedFields
            ),
            proposed: revision(
                id: "proposed:\(review.id)",
                snapshot: review.proposedSnapshot,
                sourceDescription: "確認用下書き",
                base: review.base?.snapshot,
                conflicts: review.conflicts,
                conflictValue: \.proposedValue,
                conflictedFields: conflictedFields
            )
        )
    }

    static func make(localRecovery: WorkLocalRecoveryReview) -> WorkConflictReviewPresentation {
        let staged = localRecovery.stagedLocalRevision
        let pendingRemote = localRecovery.pendingRemoteMaterialization?.revision
        let alternate = staged ?? pendingRemote ?? localRecovery.materializedRevision
        let hasAlternate = staged != nil || pendingRemote != nil
        let alternateIsRemote = staged == nil && pendingRemote != nil
        let thirdRevision = staged != nil && pendingRemote != nil
            ? pendingRemote ?? localRecovery.materializedRevision
            : localRecovery.materializedRevision
        let thirdIsPendingRemote = staged != nil && pendingRemote != nil
        let allFields = Set(WorkConflictField.allCases)
        return WorkConflictReviewPresentation(
            workTitle: localRecovery.observedPackageSnapshot.title,
            local: revision(
                id: "observed:\(localRecovery.observedPackageSnapshot.documentID)",
                snapshot: localRecovery.observedPackageSnapshot,
                sourceDescription: "現在の原稿パッケージ",
                base: localRecovery.materializedRevision.snapshot,
                conflicts: [],
                conflictValue: \.localValue,
                conflictedFields: allFields
            ),
            remote: revision(
                alternate,
                sourceDescription: alternateIsRemote
                    ? "同期記録に残っているiCloudの版"
                    : "同期記録に残っている端末内の版",
                base: localRecovery.materializedRevision.snapshot,
                conflicts: [],
                conflictValue: \.remoteValue,
                conflictedFields: allFields
            ),
            proposed: revision(
                thirdRevision,
                sourceDescription: thirdIsPendingRemote
                    ? "同期記録に残っているiCloudの版"
                    : "前回確定した共通版",
                base: localRecovery.materializedRevision.snapshot,
                conflicts: [],
                conflictValue: \.proposedValue,
                conflictedFields: []
            ),
            heading: "端末内の保存内容を確認してください",
            message: "保存の途中で終了した可能性があります。現在の原稿と、同期記録に残っている版を比べて再開する内容を選べます。",
            footnote: "選ぶまでは両方の版を保持し、原稿の編集を再開しません。",
            localPanelTitle: "現在の原稿",
            remotePanelTitle: alternateIsRemote ? "iCloudの保存版" : "端末内の保存版",
            proposedPanelTitle: thirdIsPendingRemote ? "iCloudの保存版" : "前回確定版",
            localActionTitle: "現在の原稿を採用",
            remoteActionTitle: alternateIsRemote ? "iCloudの保存版を採用" : "端末内の保存版を採用",
            proposedActionTitle: "iCloudの保存版を採用",
            localActionHint: "現在の原稿パッケージを再開する版にします",
            remoteActionHint: alternateIsRemote
                ? "iCloudから取得して端末内に保持している版を再開する版にします"
                : "端末内の同期履歴に残る保存途中の版を再開する版にします",
            proposedActionHint: "iCloudから取得して端末内に保持している統合待ちの版を再開する版にします",
            canChooseRemote: hasAlternate,
            canChooseProposed: thirdIsPendingRemote
        )
    }

    private static func revision(
        _ revision: WorkRevision,
        sourceDescription: String,
        base: WorkSnapshot?,
        conflicts: [WorkFieldConflict],
        conflictValue: KeyPath<WorkFieldConflict, String?>,
        conflictedFields: Set<WorkConflictField>
    ) -> WorkConflictRevisionPresentation {
        self.revision(
            id: revision.revisionID.description,
            snapshot: revision.snapshot,
            sourceDescription: sourceDescription,
            base: base,
            conflicts: conflicts,
            conflictValue: conflictValue,
            conflictedFields: conflictedFields
        )
    }

    private static func revision(
        id: String,
        snapshot: WorkSnapshot,
        sourceDescription: String,
        base: WorkSnapshot?,
        conflicts: [WorkFieldConflict],
        conflictValue: KeyPath<WorkFieldConflict, String?>,
        conflictedFields: Set<WorkConflictField>
    ) -> WorkConflictRevisionPresentation {
        let changed = changedFields(from: base, to: snapshot)
        let fields = WorkConflictField.allCases.compactMap { field -> WorkConflictFieldSummary? in
            let matching = conflicts.filter { self.field(for: $0) == field }
            guard changed.contains(field) || !matching.isEmpty || conflictedFields.contains(field) else {
                return nil
            }
            return WorkConflictFieldSummary(
                field,
                detail: detail(
                    for: field,
                    snapshot: snapshot,
                    conflicts: matching,
                    conflictValue: conflictValue
                ),
                requiresChoice: conflictedFields.contains(field)
            )
        }
        let conflictCount = fields.lazy.filter(\.requiresChoice).count
        let savedDescription = conflictCount == 0
            ? "変更 \(fields.count)項目"
            : "変更 \(fields.count)項目・選択が必要 \(conflictCount)項目"
        return WorkConflictRevisionPresentation(
            id: id,
            sourceDescription: sourceDescription,
            savedDescription: savedDescription,
            changes: fields,
            details: details(for: snapshot)
        )
    }

    private static func details(for snapshot: WorkSnapshot) -> [WorkConflictFieldDetail] {
        WorkConflictField.allCases.map { field in
            WorkConflictFieldDetail(field: field, blocks: detailBlocks(for: field, snapshot: snapshot))
        }
    }

    private static func detailBlocks(
        for field: WorkConflictField,
        snapshot: WorkSnapshot
    ) -> [WorkConflictDetailBlock] {
        let chapters = Dictionary(uniqueKeysWithValues: snapshot.chapters.map { ($0.id, $0) })
        let episodes = Dictionary(uniqueKeysWithValues: snapshot.episodes.map { ($0.id, $0) })
        let chapterTitles = Dictionary(uniqueKeysWithValues: snapshot.chapters.map { ($0.id, $0.title) })
        switch field {
        case .title:
            return [detailBlock("作品タイトル", snapshot.title, id: "document.title")]
        case .synopsis:
            return [detailBlock("あらすじ", snapshot.synopsis, id: "document.synopsis")]
        case .chapters:
            return snapshot.chapterOrder.enumerated().compactMap { index, id in
                guard let chapter = chapters[id] else { return nil }
                return detailBlock("\(index + 1)章目", chapter.title, id: "chapter.\(id)")
            }
        case .episodes:
            return orderedEpisodes(snapshot, chapters: chapters, episodes: episodes).map { value in
                detailBlock(value.location, value.episode.title, id: "episode-title.\(value.episode.id)")
            }
        case .episodeBodies:
            return orderedEpisodes(snapshot, chapters: chapters, episodes: episodes).map { value in
                detailBlock(value.location, value.episode.content, id: "episode-body.\(value.episode.id)")
            }
        case .episodeMemos:
            return orderedEpisodes(snapshot, chapters: chapters, episodes: episodes).map { value in
                detailBlock(value.location, value.episode.memo, id: "episode-memo.\(value.episode.id)")
            }
        case .characters:
            let values = Dictionary(uniqueKeysWithValues: snapshot.characters.map { ($0.id, $0) })
            return snapshot.characterOrder.enumerated().compactMap { index, id in
                guard let value = values[id] else { return nil }
                return detailBlock(
                    "\(index + 1)人目・\(value.name)",
                    labeled([
                        ("名前", value.name), ("かな", value.kana), ("メモ", value.memo),
                        ("色", value.colorHex), ("役割", value.role), ("年齢", value.age),
                        ("性別", value.gender), ("一人称", value.firstPerson),
                        ("二人称", value.secondPerson), ("話し方", value.speechStyle),
                        ("外見", value.appearance), ("性格", value.personality),
                        ("背景", value.background)
                    ]),
                    id: "character.\(id)"
                )
            }
        case .plotCards:
            let values = Dictionary(uniqueKeysWithValues: snapshot.plotCards.map { ($0.id, $0) })
            return snapshot.plotCardOrder.enumerated().compactMap { index, id in
                guard let value = values[id] else { return nil }
                return detailBlock(
                    "\(index + 1)件目・\(value.title)",
                    labeled([
                        ("タイトル", value.title), ("メモ", value.memo),
                        ("章", value.chapterID.flatMap { chapterTitles[$0] })
                    ]),
                    id: "plot.\(id)"
                )
            }
        case .flags:
            let values = Dictionary(uniqueKeysWithValues: snapshot.flags.map { ($0.id, $0) })
            return snapshot.flagOrder.enumerated().compactMap { index, id in
                guard let value = values[id] else { return nil }
                return detailBlock(
                    "\(index + 1)件目・\(value.title)",
                    labeled([
                        ("タイトル", value.title), ("メモ", value.note),
                        ("回収済み", value.isResolved ? "はい" : "いいえ"),
                        ("設置章", value.plantedChapterID.flatMap { chapterTitles[$0] }),
                        ("回収章", value.resolvedChapterID.flatMap { chapterTitles[$0] })
                    ]),
                    id: "flag.\(id)"
                )
            }
        case .worldNotes:
            let values = Dictionary(uniqueKeysWithValues: snapshot.worldNotes.map { ($0.id, $0) })
            return snapshot.worldNoteOrder.enumerated().compactMap { index, id in
                guard let value = values[id] else { return nil }
                return detailBlock(
                    "\(index + 1)件目・\(value.title)",
                    value.content,
                    id: "world.\(id)"
                )
            }
        }
    }

    private static func orderedEpisodes(
        _ snapshot: WorkSnapshot,
        chapters: [WorkStableID: WorkChapterSnapshot],
        episodes: [WorkStableID: WorkEpisodeSnapshot]
    ) -> [(location: String, episode: WorkEpisodeSnapshot)] {
        snapshot.chapterOrder.enumerated().flatMap { chapterIndex, chapterID in
            guard let chapter = chapters[chapterID] else {
                return [(location: String, episode: WorkEpisodeSnapshot)]()
            }
            return chapter.episodeOrder.enumerated().compactMap { episodeIndex, episodeID in
                guard let episode = episodes[episodeID] else { return nil }
                return (
                    "\(chapterIndex + 1)章目「\(chapter.title)」・\(episodeIndex + 1)話目「\(episode.title)」",
                    episode
                )
            }
        }
    }

    private static func detailBlock(
        _ title: String,
        _ content: String,
        id: String
    ) -> WorkConflictDetailBlock {
        WorkConflictDetailBlock(id: id, title: title, content: content)
    }

    private static func labeled(_ values: [(String, String?)]) -> String {
        values.map { label, value in
            "\(label): \(value ?? "（未設定）")"
        }.joined(separator: "\n")
    }

    private static func changedFields(
        from base: WorkSnapshot?,
        to snapshot: WorkSnapshot
    ) -> Set<WorkConflictField> {
        guard let base else { return Set(WorkConflictField.allCases) }
        var fields: Set<WorkConflictField> = []
        if base.title != snapshot.title {
            fields.insert(.title)
        }
        if base.synopsis != snapshot.synopsis {
            fields.insert(.synopsis)
        }
        if base.chapterOrder != snapshot.chapterOrder
            || chapterTitles(base) != chapterTitles(snapshot) {
            fields.insert(.chapters)
        }
        if episodePlacement(base) != episodePlacement(snapshot)
            || episodeTitles(base) != episodeTitles(snapshot) {
            fields.insert(.episodes)
        }
        if episodeValues(base, \.content) != episodeValues(snapshot, \.content) {
            fields.insert(.episodeBodies)
        }
        if episodeValues(base, \.memo) != episodeValues(snapshot, \.memo) {
            fields.insert(.episodeMemos)
        }
        if base.characterOrder != snapshot.characterOrder || base.characters != snapshot.characters {
            fields.insert(.characters)
        }
        if base.plotCardOrder != snapshot.plotCardOrder || base.plotCards != snapshot.plotCards {
            fields.insert(.plotCards)
        }
        if base.flagOrder != snapshot.flagOrder || base.flags != snapshot.flags {
            fields.insert(.flags)
        }
        if base.worldNoteOrder != snapshot.worldNoteOrder || base.worldNotes != snapshot.worldNotes {
            fields.insert(.worldNotes)
        }
        return fields
    }

    private static func detail(
        for field: WorkConflictField,
        snapshot: WorkSnapshot,
        conflicts: [WorkFieldConflict],
        conflictValue: KeyPath<WorkFieldConflict, String?>
    ) -> String {
        if let first = conflicts.first {
            let rendered = render(first[keyPath: conflictValue])
            if conflicts.count == 1 {
                return "選択が必要: \(rendered)"
            }
            return "選択が必要な変更 \(conflicts.count)件（例: \(rendered)）"
        }
        switch field {
        case .title:
            return "「\(compact(snapshot.title))」"
        case .synopsis:
            return "あらすじを変更"
        case .chapters:
            return "章構成を変更（\(snapshot.chapters.count)章）"
        case .episodes:
            return "話構成を変更（\(snapshot.episodes.count)話）"
        case .episodeBodies:
            return "本文を変更"
        case .episodeMemos:
            return "話メモを変更"
        case .characters:
            return "登場人物を変更（\(snapshot.characters.count)人）"
        case .plotCards:
            return "プロットを変更（\(snapshot.plotCards.count)件）"
        case .flags:
            return "伏線を変更（\(snapshot.flags.count)件）"
        case .worldNotes:
            return "世界観を変更（\(snapshot.worldNotes.count)件）"
        }
    }

    private static func field(for conflict: WorkFieldConflict) -> WorkConflictField {
        switch conflict.entityKind {
        case .document:
            conflict.field == "title" || conflict.field == "$ancestry" ? .title : .synopsis
        case .chapter:
            .chapters
        case .episode:
            switch conflict.field {
            case "content": .episodeBodies
            case "memo": .episodeMemos
            default: .episodes
            }
        case .character:
            .characters
        case .plotCard:
            .plotCards
        case .flag:
            .flags
        case .worldNote:
            .worldNotes
        case .order:
            if conflict.path.contains("episodes") || conflict.path.contains("episodeOrder") {
                .episodes
            } else if conflict.path.hasPrefix("characters") {
                .characters
            } else if conflict.path.hasPrefix("plotCards") {
                .plotCards
            } else if conflict.path.hasPrefix("flags") {
                .flags
            } else if conflict.path.hasPrefix("worldNotes") {
                .worldNotes
            } else {
                .chapters
            }
        }
    }

    private static func chapterTitles(_ snapshot: WorkSnapshot) -> [WorkStableID: String] {
        Dictionary(uniqueKeysWithValues: snapshot.chapters.map { ($0.id, $0.title) })
    }

    private static func episodePlacement(_ snapshot: WorkSnapshot) -> [WorkStableID: [WorkStableID]] {
        Dictionary(uniqueKeysWithValues: snapshot.chapters.map { ($0.id, $0.episodeOrder) })
    }

    private static func episodeTitles(_ snapshot: WorkSnapshot) -> [WorkStableID: String] {
        Dictionary(uniqueKeysWithValues: snapshot.episodes.map { ($0.id, $0.title) })
    }

    private static func episodeValues(
        _ snapshot: WorkSnapshot,
        _ keyPath: KeyPath<WorkEpisodeSnapshot, String>
    ) -> [WorkStableID: String] {
        Dictionary(uniqueKeysWithValues: snapshot.episodes.map { ($0.id, $0[keyPath: keyPath]) })
    }

    private static func render(_ value: String?) -> String {
        guard let value else { return "削除" }
        return "「\(compact(value))」"
    }

    private static func compact(_ value: String) -> String {
        let flattened = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flattened.isEmpty else { return "空欄" }
        guard flattened.count > 56 else { return flattened }
        return String(flattened.prefix(56)) + "…"
    }
}
