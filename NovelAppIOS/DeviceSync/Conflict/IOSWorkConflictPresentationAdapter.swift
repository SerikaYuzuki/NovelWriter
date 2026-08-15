import Foundation
import NovelSync

struct IOSWorkLocalRecoveryPresentation {
    enum Source: Sendable, Equatable {
        case observedPackage
        case stagedLocal
        case pendingRemote
    }

    let review: WorkLocalRecoveryReview
    let presentation: IOSWorkConflictReviewPresentation
    let remoteSource: Source
    let proposedSource: Source?

    init(review: WorkLocalRecoveryReview) {
        self.review = review
        let allFields = Set(IOSWorkConflictField.allCases)
        let observed = IOSWorkConflictRevisionPresentation(
            id: "observed-package",
            snapshot: review.observedPackageSnapshot,
            sourceDescription: "現在の作品パッケージ",
            savedDescription: "最後に読み込めた端末内の版",
            base: nil,
            conflictedFields: allFields
        )
        let staged = review.stagedLocalRevision.map { revision in
            IOSWorkConflictRevisionPresentation(
                revision: revision,
                sourceDescription: "保存直前の端末内履歴",
                base: nil,
                conflictedFields: allFields
            )
        }
        let pending = review.pendingRemoteMaterialization.map { pending in
            IOSWorkConflictRevisionPresentation(
                revision: pending.revision,
                sourceDescription: "統合待ちの同期版",
                base: nil,
                conflictedFields: allFields
            )
        }
        if let staged {
            remoteSource = .stagedLocal
            proposedSource = pending == nil ? nil : .pendingRemote
            presentation = IOSWorkConflictReviewPresentation(
                workTitle: review.observedPackageSnapshot.title,
                local: observed,
                remote: staged,
                proposed: pending,
                localPanelTitle: "現在のパッケージ",
                remotePanelTitle: "保存途中の端末内版",
                proposedPanelTitle: "iCloudから取得した統合待ち版",
                localActionTitle: "現在のパッケージを採用",
                remoteActionTitle: "保存途中の端末内版を採用",
                proposedActionTitle: "iCloudから取得した統合待ち版を採用",
                localActionHint: "現在の作品パッケージを再開する版にします",
                remoteActionHint: "端末内の同期履歴に残る保存途中の版を再開する版にします",
                proposedActionHint: "iCloudから取得して端末内に保持している統合待ちの版を再開する版にします"
            )
        } else if let pending {
            remoteSource = .pendingRemote
            proposedSource = nil
            presentation = IOSWorkConflictReviewPresentation(
                workTitle: review.observedPackageSnapshot.title,
                local: observed,
                remote: pending,
                proposed: nil,
                localPanelTitle: "現在のパッケージ",
                remotePanelTitle: "iCloudから取得した統合待ち版",
                proposedPanelTitle: "確認用下書き",
                localActionTitle: "現在のパッケージを採用",
                remoteActionTitle: "iCloudから取得した統合待ち版を採用",
                localActionHint: "現在の作品パッケージを再開する版にします",
                remoteActionHint: "iCloudから取得して端末内に保持している統合待ちの版を再開する版にします"
            )
        } else {
            // DomainのreviewRequired契約上は到達しないが、表示値を欠落させない。
            remoteSource = .observedPackage
            proposedSource = nil
            presentation = IOSWorkConflictReviewPresentation(
                workTitle: review.observedPackageSnapshot.title,
                local: observed,
                remote: observed,
                proposed: nil,
                localPanelTitle: "現在のパッケージ",
                remotePanelTitle: "前回確定版",
                proposedPanelTitle: "確認用下書き",
                localActionTitle: "現在のパッケージを採用",
                remoteActionTitle: "前回確定版を採用",
                localActionHint: "現在の作品パッケージを再開する版にします",
                remoteActionHint: "端末内の同期履歴で前回確定した版を再開する版にします"
            )
        }
    }

    func domainChoice(for choice: IOSWorkConflictReviewChoice) -> WorkLocalRecoveryChoice? {
        switch choice {
        case .keepLocal:
            .keepObservedPackage
        case .keepRemote:
            domainChoice(for: remoteSource)
        case .useProposed:
            proposedSource.flatMap(domainChoice(for:))
        }
    }

    private func domainChoice(for source: Source) -> WorkLocalRecoveryChoice? {
        switch source {
        case .observedPackage: .keepObservedPackage
        case .stagedLocal: .materializeStaged
        case .pendingRemote: .materializePendingRemote
        }
    }
}

extension IOSWorkConflictReviewPresentation {
    init(review: WorkConflictReview) {
        let base = review.base?.snapshot
        let allFieldsRequireChoice = review.base == nil || review.conflicts.contains {
            $0.path == "document.$ancestry" || $0.reason == .mergeBudgetExceeded
        }
        let conflictedFields = allFieldsRequireChoice
            ? Set(IOSWorkConflictField.allCases)
            : Set(review.conflicts.map(IOSWorkConflictField.init(conflict:)))
        let local = IOSWorkConflictRevisionPresentation(
            revision: review.local,
            sourceDescription: "このiPhoneで保存",
            base: base,
            conflictedFields: conflictedFields
        )
        let remote = IOSWorkConflictRevisionPresentation(
            revision: review.remote,
            sourceDescription: "iCloudから取得",
            base: base,
            conflictedFields: conflictedFields
        )
        let proposed = IOSWorkConflictRevisionPresentation(
            id: "proposed-\(review.id)",
            snapshot: review.proposedSnapshot,
            sourceDescription: "確認用下書き",
            savedDescription: "安全に統合できた変更を反映",
            base: base,
            conflictedFields: conflictedFields
        )
        self.init(
            workTitle: review.local.snapshot.title,
            local: local,
            remote: remote,
            proposed: proposed
        )
    }
}

private extension IOSWorkConflictRevisionPresentation {
    init(
        revision: WorkRevision,
        sourceDescription: String,
        base: WorkSnapshot?,
        conflictedFields: Set<IOSWorkConflictField>
    ) {
        self.init(
            id: revision.revisionID.rawValue.uuidString,
            snapshot: revision.snapshot,
            sourceDescription: sourceDescription,
            savedDescription: revision.clientCreatedAt.formatted(
                date: .abbreviated,
                time: .shortened
            ),
            base: base,
            conflictedFields: conflictedFields
        )
    }

    init(
        id: String,
        snapshot: WorkSnapshot,
        sourceDescription: String,
        savedDescription: String,
        base: WorkSnapshot?,
        conflictedFields: Set<IOSWorkConflictField>
    ) {
        self.init(
            id: id,
            sourceDescription: sourceDescription,
            savedDescription: savedDescription,
            changes: IOSWorkConflictField.allCases.map { field in
                IOSWorkConflictFieldSummary(
                    field,
                    detail: field.detail(in: snapshot, comparedWith: base),
                    requiresChoice: conflictedFields.contains(field)
                )
            },
            details: IOSWorkConflictField.allCases.map { field in
                IOSWorkConflictFieldDetail(
                    field: field,
                    blocks: field.detailBlocks(in: snapshot)
                )
            }
        )
    }
}

private extension IOSWorkConflictField {
    init(conflict: WorkFieldConflict) {
        switch conflict.entityKind {
        case .document:
            self = conflict.field == "title" ? .title : .synopsis
        case .chapter:
            self = .chapters
        case .episode:
            switch conflict.field {
            case "content": self = .episodeBodies
            case "memo": self = .episodeMemos
            default: self = .episodes
            }
        case .character:
            self = .characters
        case .plotCard:
            self = .plotCards
        case .flag:
            self = .flags
        case .worldNote:
            self = .worldNotes
        case .order:
            if conflict.path.hasPrefix("chapters."), conflict.path.contains("episodes") {
                self = .episodes
            } else if conflict.path.hasPrefix("chapters") {
                self = .chapters
            } else if conflict.path.hasPrefix("characters") {
                self = .characters
            } else if conflict.path.hasPrefix("plotCards") {
                self = .plotCards
            } else if conflict.path.hasPrefix("flags") {
                self = .flags
            } else {
                self = .worldNotes
            }
        }
    }

    func detail(in snapshot: WorkSnapshot, comparedWith base: WorkSnapshot?) -> String {
        switch self {
        case .title:
            quoted(snapshot.title.isEmpty ? "名称未設定" : snapshot.title)
        case .synopsis:
            excerpt(snapshot.synopsis, empty: "あらすじなし")
        case .chapters:
            collectionDetail(
                names: orderedChapterTitles(snapshot),
                changed: base.map { orderedChapterTitles($0) != orderedChapterTitles(snapshot) }
            )
        case .episodes:
            collectionDetail(
                names: orderedEpisodeTitles(snapshot),
                changed: base.map { episodeStructure($0) != episodeStructure(snapshot) }
            )
        case .episodeBodies:
            changedEpisodeTextDetail(snapshot: snapshot, base: base, keyPath: \.content, empty: "本文なし")
        case .episodeMemos:
            changedEpisodeTextDetail(snapshot: snapshot, base: base, keyPath: \.memo, empty: "話メモなし")
        case .characters:
            collectionDetail(
                names: snapshot.characterOrder.compactMap { id in
                    snapshot.characters.first { $0.id == id }?.name
                },
                changed: base.map { $0.characters != snapshot.characters || $0.characterOrder != snapshot.characterOrder }
            )
        case .plotCards:
            collectionDetail(
                names: snapshot.plotCardOrder.compactMap { id in
                    snapshot.plotCards.first { $0.id == id }?.title
                },
                changed: base.map { $0.plotCards != snapshot.plotCards || $0.plotCardOrder != snapshot.plotCardOrder }
            )
        case .flags:
            collectionDetail(
                names: snapshot.flagOrder.compactMap { id in
                    snapshot.flags.first { $0.id == id }?.title
                },
                changed: base.map { $0.flags != snapshot.flags || $0.flagOrder != snapshot.flagOrder }
            )
        case .worldNotes:
            collectionDetail(
                names: snapshot.worldNoteOrder.compactMap { id in
                    snapshot.worldNotes.first { $0.id == id }?.title
                },
                changed: base.map { $0.worldNotes != snapshot.worldNotes || $0.worldNoteOrder != snapshot.worldNoteOrder }
            )
        }
    }

    func detailBlocks(in snapshot: WorkSnapshot) -> [IOSWorkConflictDetailBlock] {
        let chapters = Dictionary(uniqueKeysWithValues: snapshot.chapters.map { ($0.id, $0) })
        let episodes = Dictionary(uniqueKeysWithValues: snapshot.episodes.map { ($0.id, $0) })
        let chapterTitles = Dictionary(uniqueKeysWithValues: snapshot.chapters.map { ($0.id, $0.title) })
        switch self {
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

    func orderedEpisodes(
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

    func detailBlock(
        _ title: String,
        _ content: String,
        id: String
    ) -> IOSWorkConflictDetailBlock {
        IOSWorkConflictDetailBlock(id: id, title: title, content: content)
    }

    func labeled(_ values: [(String, String?)]) -> String {
        values.map { label, value in
            "\(label): \(value ?? "（未設定）")"
        }.joined(separator: "\n")
    }

    func orderedChapterTitles(_ snapshot: WorkSnapshot) -> [String] {
        snapshot.chapterOrder.compactMap { id in
            snapshot.chapters.first { $0.id == id }?.title
        }
    }

    func orderedEpisodeTitles(_ snapshot: WorkSnapshot) -> [String] {
        let chapters = Dictionary(uniqueKeysWithValues: snapshot.chapters.map { ($0.id, $0) })
        let episodes = Dictionary(uniqueKeysWithValues: snapshot.episodes.map { ($0.id, $0) })
        return snapshot.chapterOrder.flatMap { chapterID in
            chapters[chapterID]?.episodeOrder.compactMap { episodes[$0]?.title } ?? []
        }
    }

    func episodeStructure(_ snapshot: WorkSnapshot) -> [[WorkStableID]] {
        let chapters = Dictionary(uniqueKeysWithValues: snapshot.chapters.map { ($0.id, $0) })
        return snapshot.chapterOrder.map { chapters[$0]?.episodeOrder ?? [] }
    }

    func changedEpisodeTextDetail(
        snapshot: WorkSnapshot,
        base: WorkSnapshot?,
        keyPath: KeyPath<WorkEpisodeSnapshot, String>,
        empty: String
    ) -> String {
        let baseEpisodes = Dictionary(uniqueKeysWithValues: (base?.episodes ?? []).map { ($0.id, $0) })
        let changed = snapshot.episodes.filter { episode in
            baseEpisodes[episode.id]?[keyPath: keyPath] != episode[keyPath: keyPath]
        }
        guard let first = changed.first else {
            guard base != nil else { return "\(snapshot.episodes.count)話" }
            return "変更なし"
        }
        let value = excerpt(first[keyPath: keyPath], empty: empty)
        return changed.count == 1 ? value : "\(changed.count)話を変更・\(value)"
    }

    func collectionDetail(names: [String], changed: Bool?) -> String {
        if changed == false {
            return "変更なし"
        }
        let visible = names.filter { !$0.isEmpty }.prefix(3).joined(separator: "、")
        guard !visible.isEmpty else { return "0件" }
        return names.count > 3 ? "\(names.count)件・\(visible)ほか" : "\(names.count)件・\(visible)"
    }

    func quoted(_ value: String) -> String {
        "「\(String(value.prefix(80)))」"
    }

    func excerpt(_ value: String, empty: String) -> String {
        let compact = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return empty }
        return quoted(compact)
    }
}
