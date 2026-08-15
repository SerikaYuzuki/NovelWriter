// The exhaustive stable-ID merge matrix is kept in one transport-neutral unit for auditability.
// swiftlint:disable:next blanket_disable_command
// swiftlint:disable file_length type_body_length function_body_length
// swiftlint:disable:next blanket_disable_command
// swiftlint:disable function_parameter_count line_length
import Foundation
import NovelCore

public enum WorkSnapshotMergeResult: Equatable, Sendable {
    case merged(WorkSnapshot)
    case conflicted(proposed: WorkSnapshot, conflicts: [WorkFieldConflict])
}

/// D-061の作品全体3-way merger。D-071のNoteSync通常経路からは呼ばない。
/// sourceとtestは履歴として残し、自動統合案はlive Appへ出さない。
public enum WorkSnapshotMerger {
    public static func merge(
        base: WorkSnapshot,
        local: WorkSnapshot,
        remote: WorkSnapshot
    ) throws -> WorkSnapshotMergeResult {
        try base.validate()
        try local.validate()
        try remote.validate()
        guard base.documentID == local.documentID,
              base.documentID == remote.documentID else {
            throw WorkSnapshotError.documentIdentityMismatch
        }
        var engine = MergeEngine(base: base, local: local, remote: remote)
        let snapshot = try engine.merge()
        return engine.conflicts.isEmpty
            ? .merged(snapshot)
            : .conflicted(proposed: snapshot, conflicts: engine.conflicts)
    }
}

private struct MergeEngine {
    let base: WorkSnapshot
    let local: WorkSnapshot
    let remote: WorkSnapshot
    var conflicts: [WorkFieldConflict] = []

    mutating func merge() throws -> WorkSnapshot {
        let documentID = base.documentID
        let title = mergeScalar(
            base.title,
            local.title,
            remote.title,
            path: "document.title",
            kind: .document,
            entityID: nil,
            field: "title"
        )
        let synopsis = mergeText(
            base.synopsis,
            local.synopsis,
            remote.synopsis,
            path: "document.synopsis",
            kind: .document,
            entityID: nil,
            field: "synopsis"
        )

        let episodes = mergeEpisodesConsideringPlacements()
        let chapters = mergeChaptersConsideringEpisodes()
        let chapterIDs = Set(chapters.map(\.id))
        let chapterOrder = mergeOrder(
            base: base.chapterOrder,
            local: local.chapterOrder,
            remote: remote.chapterOrder,
            proposedIDs: chapterIDs,
            path: "chapters.$order"
        )
        let episodeIDs = Set(episodes.map(\.id))
        let placements = mergeEpisodePlacements(for: episodeIDs)
        let normalizedChapters = chapters.map { chapter in
            let assigned = Set(placements.compactMap { id, chapterID in
                chapterID == chapter.id ? id : nil
            })
            return WorkChapterSnapshot(
                id: chapter.id,
                title: chapter.title,
                episodeOrder: mergeOrder(
                    base: findChapter(with: chapter.id, in: base)?.episodeOrder ?? [],
                    local: findChapter(with: chapter.id, in: local)?.episodeOrder ?? [],
                    remote: findChapter(with: chapter.id, in: remote)?.episodeOrder ?? [],
                    proposedIDs: assigned,
                    path: "chapters.\(chapter.id).episodes.$order"
                )
            )
        }
        let referencedEpisodeIDs = Set(normalizedChapters.flatMap(\.episodeOrder))
        let normalizedEpisodes = episodes.filter { referencedEpisodeIDs.contains($0.id) }

        let characters = mergeEntities(
            engine: &self,
            base: base.characters,
            local: local.characters,
            remote: remote.characters,
            baseOrder: base.characterOrder,
            localOrder: local.characterOrder,
            remoteOrder: remote.characterOrder,
            kind: .character,
            mergeFields: { engine, base, local, remote in
                engine.mergeCharacter(base, local, remote)
            }
        )
        let characterOrder = mergeOrder(
            base: base.characterOrder,
            local: local.characterOrder,
            remote: remote.characterOrder,
            proposedIDs: Set(characters.map(\.id)),
            path: "characters.$order"
        )
        let plotCards = mergeEntities(
            engine: &self,
            base: base.plotCards,
            local: local.plotCards,
            remote: remote.plotCards,
            baseOrder: base.plotCardOrder,
            localOrder: local.plotCardOrder,
            remoteOrder: remote.plotCardOrder,
            kind: .plotCard,
            mergeFields: { engine, base, local, remote in
                engine.mergePlotCard(base, local, remote)
            }
        ).map { card in
            WorkPlotCardSnapshot(
                id: card.id,
                title: card.title,
                memo: card.memo,
                chapterID: normalizeChapterReference(
                    card.chapterID,
                    entityID: card.id,
                    kind: .plotCard,
                    field: "chapterID",
                    validChapterIDs: chapterIDs
                )
            )
        }
        let plotCardOrder = mergeOrder(
            base: base.plotCardOrder,
            local: local.plotCardOrder,
            remote: remote.plotCardOrder,
            proposedIDs: Set(plotCards.map(\.id)),
            path: "plotCards.$order"
        )
        let flags = mergeEntities(
            engine: &self,
            base: base.flags,
            local: local.flags,
            remote: remote.flags,
            baseOrder: base.flagOrder,
            localOrder: local.flagOrder,
            remoteOrder: remote.flagOrder,
            kind: .flag,
            mergeFields: { engine, base, local, remote in
                engine.mergeFlag(base, local, remote)
            }
        ).map { flag in
            WorkFlagSnapshot(
                id: flag.id,
                title: flag.title,
                note: flag.note,
                isResolved: flag.isResolved,
                plantedChapterID: normalizeChapterReference(
                    flag.plantedChapterID,
                    entityID: flag.id,
                    kind: .flag,
                    field: "plantedChapterID",
                    validChapterIDs: chapterIDs
                ),
                resolvedChapterID: normalizeChapterReference(
                    flag.resolvedChapterID,
                    entityID: flag.id,
                    kind: .flag,
                    field: "resolvedChapterID",
                    validChapterIDs: chapterIDs
                )
            )
        }
        let flagOrder = mergeOrder(
            base: base.flagOrder,
            local: local.flagOrder,
            remote: remote.flagOrder,
            proposedIDs: Set(flags.map(\.id)),
            path: "flags.$order"
        )
        let worldNotes = mergeEntities(
            engine: &self,
            base: base.worldNotes,
            local: local.worldNotes,
            remote: remote.worldNotes,
            baseOrder: base.worldNoteOrder,
            localOrder: local.worldNoteOrder,
            remoteOrder: remote.worldNoteOrder,
            kind: .worldNote,
            mergeFields: { engine, base, local, remote in
                engine.mergeWorldNote(base, local, remote)
            }
        )
        let worldNoteOrder = mergeOrder(
            base: base.worldNoteOrder,
            local: local.worldNoteOrder,
            remote: remote.worldNoteOrder,
            proposedIDs: Set(worldNotes.map(\.id)),
            path: "worldNotes.$order"
        )

        let document = try NovelDocument(
            id: documentID.rawValue,
            title: title,
            synopsis: synopsis,
            chapters: materializeChapters(
                order: chapterOrder,
                chapters: normalizedChapters,
                episodes: normalizedEpisodes
            ),
            characters: materializeCharacters(order: characterOrder, values: characters),
            plotCards: materializePlotCards(order: plotCardOrder, values: plotCards),
            flags: materializeFlags(order: flagOrder, values: flags),
            worldNotes: materializeWorldNotes(order: worldNoteOrder, values: worldNotes)
        )
        return try WorkSnapshot(document: document)
    }

    mutating func mergeEpisode(
        _ base: WorkEpisodeSnapshot,
        _ local: WorkEpisodeSnapshot,
        _ remote: WorkEpisodeSnapshot
    ) -> WorkEpisodeSnapshot {
        WorkEpisodeSnapshot(
            id: base.id,
            title: mergeScalarField(base.title, local.title, remote.title, entity: base.id, kind: .episode, field: "title"),
            content: mergeTextField(base.content, local.content, remote.content, entity: base.id, kind: .episode, field: "content"),
            memo: mergeTextField(base.memo, local.memo, remote.memo, entity: base.id, kind: .episode, field: "memo")
        )
    }

    /// Episode本体が同じでもchapter間moveは編集であるため、delete-vs-moveを
    /// generic entity mergeの「delete-vs-unchanged」に落とさない。
    mutating func mergeEpisodesConsideringPlacements() -> [WorkEpisodeSnapshot] {
        let baseMap = map(base.episodes)
        let localMap = map(local.episodes)
        let remoteMap = map(remote.episodes)
        let basePlacements = episodePlacements(in: base)
        let localPlacements = episodePlacements(in: local)
        let remotePlacements = episodePlacements(in: remote)
        let ids = Set(baseMap.keys).union(localMap.keys).union(remoteMap.keys)
        return ids.sortedByUUIDString().compactMap { id in
            let baseValue = baseMap[id]
            let localValue = localMap[id]
            let remoteValue = remoteMap[id]
            guard let baseValue else {
                return mergeConcurrentAddition(localValue, remoteValue, id: id, kind: .episode)
            }
            switch (localValue, remoteValue) {
            case (nil, nil):
                return nil
            case let (local?, remote?):
                return mergeEpisode(baseValue, local, remote)
            case let (nil, remote?):
                guard remote == baseValue,
                      remotePlacements[id] == basePlacements[id],
                      !episodeWasReordered(
                          id,
                          basePlacement: basePlacements[id],
                          sidePlacement: remotePlacements[id],
                          side: self.remote
                      ) else {
                    appendDeleteConflict(id: id, kind: .episode, localDeleted: true)
                    return remote
                }
                return nil
            case let (local?, nil):
                guard local == baseValue,
                      localPlacements[id] == basePlacements[id],
                      !episodeWasReordered(
                          id,
                          basePlacement: basePlacements[id],
                          sidePlacement: localPlacements[id],
                          side: self.local
                      ) else {
                    appendDeleteConflict(id: id, kind: .episode, localDeleted: false)
                    return local
                }
                return nil
            }
        }
    }

    mutating func mergeCharacter(
        _ base: WorkCharacterSnapshot,
        _ local: WorkCharacterSnapshot,
        _ remote: WorkCharacterSnapshot
    ) -> WorkCharacterSnapshot {
        WorkCharacterSnapshot(
            id: base.id,
            name: scalar(base.name, local.name, remote.name, base.id, .character, "name"),
            kana: scalar(base.kana, local.kana, remote.kana, base.id, .character, "kana"),
            memo: text(base.memo, local.memo, remote.memo, base.id, .character, "memo"),
            colorHex: scalar(base.colorHex, local.colorHex, remote.colorHex, base.id, .character, "colorHex"),
            role: scalar(base.role, local.role, remote.role, base.id, .character, "role"),
            age: scalar(base.age, local.age, remote.age, base.id, .character, "age"),
            gender: scalar(base.gender, local.gender, remote.gender, base.id, .character, "gender"),
            firstPerson: scalar(base.firstPerson, local.firstPerson, remote.firstPerson, base.id, .character, "firstPerson"),
            secondPerson: scalar(base.secondPerson, local.secondPerson, remote.secondPerson, base.id, .character, "secondPerson"),
            speechStyle: textOptional(base.speechStyle, local.speechStyle, remote.speechStyle, base.id, .character, "speechStyle"),
            appearance: textOptional(base.appearance, local.appearance, remote.appearance, base.id, .character, "appearance"),
            personality: textOptional(base.personality, local.personality, remote.personality, base.id, .character, "personality"),
            background: textOptional(base.background, local.background, remote.background, base.id, .character, "background")
        )
    }

    mutating func mergePlotCard(
        _ base: WorkPlotCardSnapshot,
        _ local: WorkPlotCardSnapshot,
        _ remote: WorkPlotCardSnapshot
    ) -> WorkPlotCardSnapshot {
        WorkPlotCardSnapshot(
            id: base.id,
            title: scalar(base.title, local.title, remote.title, base.id, .plotCard, "title"),
            memo: text(base.memo, local.memo, remote.memo, base.id, .plotCard, "memo"),
            chapterID: mergeChapterReference(
                base.chapterID,
                local.chapterID,
                remote.chapterID,
                entity: base.id,
                kind: .plotCard,
                field: "chapterID"
            )
        )
    }

    mutating func mergeFlag(
        _ base: WorkFlagSnapshot,
        _ local: WorkFlagSnapshot,
        _ remote: WorkFlagSnapshot
    ) -> WorkFlagSnapshot {
        WorkFlagSnapshot(
            id: base.id,
            title: scalar(base.title, local.title, remote.title, base.id, .flag, "title"),
            note: text(base.note, local.note, remote.note, base.id, .flag, "note"),
            isResolved: scalar(base.isResolved, local.isResolved, remote.isResolved, base.id, .flag, "isResolved"),
            plantedChapterID: mergeChapterReference(
                base.plantedChapterID,
                local.plantedChapterID,
                remote.plantedChapterID,
                entity: base.id,
                kind: .flag,
                field: "plantedChapterID"
            ),
            resolvedChapterID: mergeChapterReference(
                base.resolvedChapterID,
                local.resolvedChapterID,
                remote.resolvedChapterID,
                entity: base.id,
                kind: .flag,
                field: "resolvedChapterID"
            )
        )
    }

    mutating func mergeWorldNote(
        _ base: WorkWorldNoteSnapshot,
        _ local: WorkWorldNoteSnapshot,
        _ remote: WorkWorldNoteSnapshot
    ) -> WorkWorldNoteSnapshot {
        WorkWorldNoteSnapshot(
            id: base.id,
            title: scalar(base.title, local.title, remote.title, base.id, .worldNote, "title"),
            content: text(base.content, local.content, remote.content, base.id, .worldNote, "content")
        )
    }

    mutating func mergeChaptersConsideringEpisodes() -> [WorkChapterSnapshot] {
        let baseMap = map(base.chapters), localMap = map(local.chapters), remoteMap = map(remote.chapters)
        let ids = Set(baseMap.keys).union(localMap.keys).union(remoteMap.keys)
        return ids.sortedByUUIDString().compactMap { id in
            let baseValue = baseMap[id], localValue = localMap[id], remoteValue = remoteMap[id]
            guard let baseValue else {
                return mergeConcurrentAddition(localValue, remoteValue, id: id, kind: .chapter)
            }
            switch (localValue, remoteValue) {
            case (nil, nil):
                return nil
            case let (local?, remote?):
                return WorkChapterSnapshot(
                    id: id,
                    title: scalar(baseValue.title, local.title, remote.title, id, .chapter, "title"),
                    episodeOrder: baseValue.episodeOrder
                )
            case let (nil, remote?):
                if chapterBundle(remote, in: self.remote) == chapterBundle(baseValue, in: base),
                   !wasMoved(id, baseOrder: base.chapterOrder, sideOrder: self.remote.chapterOrder) {
                    return nil
                }
                appendDeleteConflict(id: id, kind: .chapter, localDeleted: true)
                return remote
            case let (local?, nil):
                if chapterBundle(local, in: self.local) == chapterBundle(baseValue, in: base),
                   !wasMoved(id, baseOrder: base.chapterOrder, sideOrder: self.local.chapterOrder) {
                    return nil
                }
                appendDeleteConflict(id: id, kind: .chapter, localDeleted: false)
                return local
            }
        }.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
    }

    mutating func mergeConcurrentAddition<Entity: Equatable & WorkMergeEntity>(
        _ local: Entity?,
        _ remote: Entity?,
        id: WorkStableID,
        kind: WorkEntityKind
    ) -> Entity? {
        switch (local, remote) {
        case (nil, nil):
            return nil
        case let (value?, nil), let (nil, value?):
            return value
        case let (local?, remote?) where local == remote:
            return local
        case let (local?, _?):
            appendConflict(WorkFieldConflict(
                path: path(kind, id, "$entity"),
                entityKind: kind,
                entityID: id,
                field: "$entity",
                reason: .addedDifferently,
                baseValue: nil,
                localValue: "present",
                remoteValue: "present",
                proposedValue: "local"
            ))
            return local
        }
    }

    mutating func appendDeleteConflict(id: WorkStableID, kind: WorkEntityKind, localDeleted: Bool) {
        appendConflict(WorkFieldConflict(
            path: path(kind, id, "$entity"),
            entityKind: kind,
            entityID: id,
            field: "$entity",
            reason: .deleteVersusEdit,
            baseValue: "present",
            localValue: localDeleted ? nil : "edited",
            remoteValue: localDeleted ? "edited" : nil,
            proposedValue: "edited"
        ))
    }

    mutating func mergeOrder(
        base: [WorkStableID],
        local: [WorkStableID],
        remote: [WorkStableID],
        proposedIDs: Set<WorkStableID>,
        path: String
    ) -> [WorkStableID] {
        let baseFiltered = base.filter(proposedIDs.contains)
        let localFiltered = local.filter(proposedIDs.contains)
        let remoteFiltered = remote.filter(proposedIDs.contains)
        let baseIDs = Set(base)
        let localCommon = localFiltered.filter(baseIDs.contains)
        let remoteCommon = remoteFiltered.filter(baseIDs.contains)
        let baseForLocal = baseFiltered.filter(Set(localCommon).contains)
        let baseForRemote = baseFiltered.filter(Set(remoteCommon).contains)
        let localChanged = localCommon != baseForLocal
        let remoteChanged = remoteCommon != baseForRemote

        let primaryCommon: [WorkStableID]
        if localChanged, remoteChanged, localCommon != remoteCommon {
            appendOrderConflict(
                path: path,
                base: baseFiltered,
                local: localFiltered,
                remote: remoteFiltered,
                proposed: localFiltered
            )
            primaryCommon = localCommon
        } else if localChanged {
            primaryCommon = localCommon
        } else if remoteChanged {
            primaryCommon = remoteCommon
        } else {
            primaryCommon = baseFiltered
        }

        var constraints = WorkOrderConstraints(nodes: proposedIDs)
        constraints.addSequence(primaryCommon)

        // A base entity retained because of delete-vs-edit must not drift to the
        // end merely because the preferred side deleted it.
        let primarySet = Set(primaryCommon)
        constraints.addAdjacentEdges(in: baseFiltered) { first, second in
            !primarySet.contains(first) || !primarySet.contains(second)
        }

        // New stable IDs carry their position through neighbouring anchors.
        // Only edges touching a new ID are imported, so an unchanged side does
        // not accidentally vote on an existing-entity reorder.
        let addedIDs = proposedIDs.subtracting(baseIDs)
        constraints.addAdjacentEdges(in: localFiltered) { first, second in
            addedIDs.contains(first) || addedIDs.contains(second)
        }
        constraints.addAdjacentEdges(in: remoteFiltered) { first, second in
            addedIDs.contains(first) || addedIDs.contains(second)
        }

        if let merged = constraints.sorted() {
            return merged
        }

        // Incompatible insertion anchors (including a cycle against the chosen
        // existing-entity order) retain every ID in a valid local-biased
        // proposal and require an explicit choice.
        var fallback = localFiltered
        insertMissingAnchored(from: baseFiltered, into: &fallback)
        insertMissingAnchored(from: remoteFiltered, into: &fallback)
        for id in proposedIDs.sortedByUUIDString() where !fallback.contains(id) {
            fallback.append(id)
        }
        appendOrderConflict(
            path: path,
            base: baseFiltered,
            local: localFiltered,
            remote: remoteFiltered,
            proposed: fallback
        )
        return fallback
    }

    mutating func appendOrderConflict(
        path: String,
        base: [WorkStableID],
        local: [WorkStableID],
        remote: [WorkStableID],
        proposed: [WorkStableID]
    ) {
        guard !conflicts.contains(where: {
            $0.path == path && $0.reason == .bothOrdersChanged
        }) else { return }
        appendConflict(WorkFieldConflict(
            path: path,
            entityKind: .order,
            entityID: nil,
            field: "$order",
            reason: .bothOrdersChanged,
            baseValue: renderOrder(base),
            localValue: renderOrder(local),
            remoteValue: renderOrder(remote),
            proposedValue: renderOrder(proposed)
        ))
    }

    mutating func mergeScalar<Value: Equatable>(
        _ base: Value,
        _ local: Value,
        _ remote: Value,
        path: String,
        kind: WorkEntityKind,
        entityID: WorkStableID?,
        field: String,
        render: (Value) -> String = { String(describing: $0) }
    ) -> Value {
        if local == remote {
            return local
        }
        if local == base {
            return remote
        }
        if remote == base {
            return local
        }
        appendConflict(WorkFieldConflict(
            path: path,
            entityKind: kind,
            entityID: entityID,
            field: field,
            reason: .sameFieldChanged,
            baseValue: render(base),
            localValue: render(local),
            remoteValue: render(remote),
            proposedValue: render(local)
        ))
        return local
    }

    mutating func mergeText(
        _ base: String,
        _ local: String,
        _ remote: String,
        path: String,
        kind: WorkEntityKind,
        entityID: WorkStableID?,
        field: String
    ) -> String {
        switch PortableThreeWayTextMerger.analyze(base: base, local: local, remote: remote) {
        case let .merged(value):
            return value
        case let .conflict(conflict):
            appendConflict(WorkFieldConflict(
                path: path,
                entityKind: kind,
                entityID: entityID,
                field: field,
                reason: conflict.reason == .inputLimitExceeded ? .textInputLimitExceeded : .textOverlap,
                baseValue: base,
                localValue: local,
                remoteValue: remote,
                proposedValue: conflict.proposedContent
            ))
            return conflict.proposedContent
        }
    }

    mutating func scalar<Value: Equatable>(
        _ base: Value,
        _ local: Value,
        _ remote: Value,
        _ id: WorkStableID,
        _ kind: WorkEntityKind,
        _ field: String
    ) -> Value {
        mergeScalar(
            base,
            local,
            remote,
            path: path(kind, id, field),
            kind: kind,
            entityID: id,
            field: field
        )
    }

    mutating func text(
        _ base: String,
        _ local: String,
        _ remote: String,
        _ id: WorkStableID,
        _ kind: WorkEntityKind,
        _ field: String
    ) -> String {
        mergeText(
            base,
            local,
            remote,
            path: path(kind, id, field),
            kind: kind,
            entityID: id,
            field: field
        )
    }

    mutating func textOptional(
        _ base: String?,
        _ local: String?,
        _ remote: String?,
        _ id: WorkStableID,
        _ kind: WorkEntityKind,
        _ field: String
    ) -> String? {
        if let base, let local, let remote {
            return text(base, local, remote, id, kind, field)
        }
        return scalar(base, local, remote, id, kind, field)
    }

    mutating func mergeScalarField(
        _ base: String,
        _ local: String,
        _ remote: String,
        entity: WorkStableID,
        kind: WorkEntityKind,
        field: String
    ) -> String {
        scalar(base, local, remote, entity, kind, field)
    }

    mutating func mergeChapterReference(
        _ baseReference: WorkStableID?,
        _ localReference: WorkStableID?,
        _ remoteReference: WorkStableID?,
        entity: WorkStableID,
        kind: WorkEntityKind,
        field: String
    ) -> WorkStableID? {
        if let baseReference {
            let localDeletedChapter = !local.chapterOrder.contains(baseReference)
            let remoteDeletedChapter = !remote.chapterOrder.contains(baseReference)
            if localDeletedChapter, !remoteDeletedChapter, localReference != remoteReference {
                appendConflict(WorkFieldConflict(
                    path: path(kind, entity, field),
                    entityKind: kind,
                    entityID: entity,
                    field: field,
                    reason: .deleteVersusEdit,
                    baseValue: baseReference.description,
                    localValue: localReference?.description,
                    remoteValue: remoteReference?.description,
                    proposedValue: remoteReference?.description
                ))
                return remoteReference
            }
            if remoteDeletedChapter, !localDeletedChapter, localReference != remoteReference {
                appendConflict(WorkFieldConflict(
                    path: path(kind, entity, field),
                    entityKind: kind,
                    entityID: entity,
                    field: field,
                    reason: .deleteVersusEdit,
                    baseValue: baseReference.description,
                    localValue: localReference?.description,
                    remoteValue: remoteReference?.description,
                    proposedValue: localReference?.description
                ))
                return localReference
            }
        }
        return scalar(baseReference, localReference, remoteReference, entity, kind, field)
    }

    mutating func mergeTextField(
        _ base: String,
        _ local: String,
        _ remote: String,
        entity: WorkStableID,
        kind: WorkEntityKind,
        field: String
    ) -> String {
        text(base, local, remote, entity, kind, field)
    }

    func chapterBundle(_ chapter: WorkChapterSnapshot, in snapshot: WorkSnapshot) -> ChapterBundle {
        let episodes = Dictionary(uniqueKeysWithValues: snapshot.episodes.map { ($0.id, $0) })
        return ChapterBundle(
            chapter: chapter,
            episodes: chapter.episodeOrder.compactMap { episodes[$0] },
            plotCards: snapshot.plotCards.filter { $0.chapterID == chapter.id },
            flags: snapshot.flags.filter {
                $0.plantedChapterID == chapter.id || $0.resolvedChapterID == chapter.id
            }
        )
    }

    mutating func mergeEpisodePlacements(
        for episodeIDs: Set<WorkStableID>
    ) -> [WorkStableID: WorkStableID] {
        let basePlacements = episodePlacements(in: base)
        let localPlacements = episodePlacements(in: local)
        let remotePlacements = episodePlacements(in: remote)
        var result: [WorkStableID: WorkStableID] = [:]
        for id in episodeIDs.sortedByUUIDString() {
            let baseChapter = basePlacements[id]
            let localChapter = localPlacements[id]
            let remoteChapter = remotePlacements[id]
            let placement: WorkStableID? = if baseChapter == nil {
                if let localChapter, let remoteChapter, localChapter != remoteChapter {
                    scalar(baseChapter, localChapter, remoteChapter, id, .episode, "chapterID")
                } else {
                    localChapter ?? remoteChapter
                }
            } else if localChapter == nil {
                remoteChapter
            } else if remoteChapter == nil {
                localChapter
            } else {
                scalar(baseChapter, localChapter, remoteChapter, id, .episode, "chapterID")
            }
            if let placement {
                result[id] = placement
            }
        }
        return result
    }

    func episodePlacements(in snapshot: WorkSnapshot) -> [WorkStableID: WorkStableID] {
        var result: [WorkStableID: WorkStableID] = [:]
        for chapter in snapshot.chapters {
            for episodeID in chapter.episodeOrder {
                result[episodeID] = chapter.id
            }
        }
        return result
    }

    func episodeWasReordered(
        _ episodeID: WorkStableID,
        basePlacement: WorkStableID?,
        sidePlacement: WorkStableID?,
        side: WorkSnapshot
    ) -> Bool {
        guard let basePlacement, basePlacement == sidePlacement,
              let baseChapter = findChapter(with: basePlacement, in: base),
              let sideChapter = findChapter(with: basePlacement, in: side) else { return false }
        return wasMoved(
            episodeID,
            baseOrder: baseChapter.episodeOrder,
            sideOrder: sideChapter.episodeOrder
        )
    }

    func findChapter(with id: WorkStableID, in snapshot: WorkSnapshot) -> WorkChapterSnapshot? {
        snapshot.chapters.first { $0.id == id }
    }

    mutating func normalizeChapterReference(
        _ reference: WorkStableID?,
        entityID: WorkStableID,
        kind: WorkEntityKind,
        field: String,
        validChapterIDs: Set<WorkStableID>
    ) -> WorkStableID? {
        guard let reference, !validChapterIDs.contains(reference) else { return reference }
        appendConflict(WorkFieldConflict(
            path: path(kind, entityID, field),
            entityKind: kind,
            entityID: entityID,
            field: field,
            reason: .deleteVersusEdit,
            baseValue: nil,
            localValue: reference.description,
            remoteValue: reference.description,
            proposedValue: nil
        ))
        return nil
    }

    func path(_ kind: WorkEntityKind, _ id: WorkStableID, _ field: String) -> String {
        "\(kind.rawValue)s.\(id).\(field)"
    }

    mutating func appendConflict(_ conflict: WorkFieldConflict) {
        let maximum = WorkSyncJournalRecord.maximumConflictCount
        guard conflicts.count < maximum else { return }
        if conflicts.count == maximum - 1 {
            conflicts.append(WorkFieldConflict(
                path: "document.$mergeBudget",
                entityKind: .document,
                entityID: nil,
                field: "$mergeBudget",
                reason: .mergeBudgetExceeded,
                baseValue: nil,
                localValue: "additional conflicts retained in local revision",
                remoteValue: "additional conflicts retained in remote revision",
                proposedValue: "safe proposed snapshot retained"
            ))
            return
        }
        conflicts.append(conflict)
    }

    func renderOrder(_ value: [WorkStableID]) -> String {
        value.map(\.description).joined(separator: ",")
    }
}

private struct ChapterBundle: Equatable {
    let chapter: WorkChapterSnapshot
    let episodes: [WorkEpisodeSnapshot]
    let plotCards: [WorkPlotCardSnapshot]
    let flags: [WorkFlagSnapshot]
}

private protocol WorkMergeEntity {
    var id: WorkStableID { get }
}

extension WorkChapterSnapshot: WorkMergeEntity {}
extension WorkEpisodeSnapshot: WorkMergeEntity {}
extension WorkCharacterSnapshot: WorkMergeEntity {}
extension WorkPlotCardSnapshot: WorkMergeEntity {}
extension WorkFlagSnapshot: WorkMergeEntity {}
extension WorkWorldNoteSnapshot: WorkMergeEntity {}

private func map<Entity: WorkMergeEntity>(_ values: [Entity]) -> [WorkStableID: Entity] {
    Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
}

private func mergeEntities<Entity: Equatable & WorkMergeEntity>(
    engine: inout MergeEngine,
    base: [Entity],
    local: [Entity],
    remote: [Entity],
    baseOrder: [WorkStableID],
    localOrder: [WorkStableID],
    remoteOrder: [WorkStableID],
    kind: WorkEntityKind,
    mergeFields: (inout MergeEngine, Entity, Entity, Entity) -> Entity
) -> [Entity] {
    let baseMap = map(base), localMap = map(local), remoteMap = map(remote)
    let ids = Set(baseMap.keys).union(localMap.keys).union(remoteMap.keys)
    return ids.sortedByUUIDString().compactMap { id in
        let baseValue = baseMap[id], localValue = localMap[id], remoteValue = remoteMap[id]
        guard let baseValue else {
            return engine.mergeConcurrentAddition(localValue, remoteValue, id: id, kind: kind)
        }
        switch (localValue, remoteValue) {
        case (nil, nil):
            return nil
        case let (local?, remote?):
            return mergeFields(&engine, baseValue, local, remote)
        case let (nil, remote?):
            guard remote != baseValue
                || wasMoved(id, baseOrder: baseOrder, sideOrder: remoteOrder) else { return nil }
            engine.appendDeleteConflict(id: id, kind: kind, localDeleted: true)
            return remote
        case let (local?, nil):
            guard local != baseValue
                || wasMoved(id, baseOrder: baseOrder, sideOrder: localOrder) else { return nil }
            engine.appendDeleteConflict(id: id, kind: kind, localDeleted: false)
            return local
        }
    }
}

private func wasMoved(
    _ id: WorkStableID,
    baseOrder: [WorkStableID],
    sideOrder: [WorkStableID]
) -> Bool {
    guard baseOrder.contains(id), sideOrder.contains(id) else { return false }
    let common = Set(baseOrder).intersection(sideOrder)
    let baseIndexes = Dictionary(uniqueKeysWithValues: baseOrder.enumerated().map {
        ($0.element, $0.offset)
    })
    let sideIndexes = Dictionary(uniqueKeysWithValues: sideOrder.enumerated().map {
        ($0.element, $0.offset)
    })
    guard let baseIDIndex = baseIndexes[id], let sideIDIndex = sideIndexes[id] else {
        return false
    }
    return common.contains { other in
        guard other != id,
              let baseOtherIndex = baseIndexes[other],
              let sideOtherIndex = sideIndexes[other] else { return false }
        return (baseIDIndex < baseOtherIndex) != (sideIDIndex < sideOtherIndex)
    }
}

private func materializeChapters(
    order: [WorkStableID],
    chapters: [WorkChapterSnapshot],
    episodes: [WorkEpisodeSnapshot]
) throws -> [Chapter] {
    let chapterMap = map(chapters), episodeMap = map(episodes)
    return try order.map { id in
        guard let chapter = chapterMap[id] else { throw WorkSnapshotError.invalidEntityReference }
        return try Chapter(
            id: ChapterID(rawValue: id.rawValue),
            title: chapter.title,
            episodes: chapter.episodeOrder.map { episodeID in
                guard let episode = episodeMap[episodeID] else {
                    throw WorkSnapshotError.invalidEntityReference
                }
                return Episode(
                    id: EpisodeID(rawValue: episodeID.rawValue),
                    title: episode.title,
                    content: episode.content,
                    memo: episode.memo
                )
            }
        )
    }
}

private func materializeCharacters(
    order: [WorkStableID],
    values: [WorkCharacterSnapshot]
) throws -> [Character] {
    let values = map(values)
    return try order.map { id in
        guard let value = values[id] else { throw WorkSnapshotError.invalidEntityReference }
        return Character(
            id: CharacterID(rawValue: id.rawValue),
            name: value.name,
            kana: value.kana,
            memo: value.memo,
            colorHex: value.colorHex,
            role: value.role,
            age: value.age,
            gender: value.gender,
            firstPerson: value.firstPerson,
            secondPerson: value.secondPerson,
            speechStyle: value.speechStyle,
            appearance: value.appearance,
            personality: value.personality,
            background: value.background
        )
    }
}

private func materializePlotCards(
    order: [WorkStableID],
    values: [WorkPlotCardSnapshot]
) throws -> [PlotCard] {
    let values = map(values)
    return try order.map { id in
        guard let value = values[id] else { throw WorkSnapshotError.invalidEntityReference }
        return PlotCard(
            id: PlotCardID(rawValue: id.rawValue),
            title: value.title,
            memo: value.memo,
            chapterID: value.chapterID.map { ChapterID(rawValue: $0.rawValue) }
        )
    }
}

private func materializeFlags(
    order: [WorkStableID],
    values: [WorkFlagSnapshot]
) throws -> [Flag] {
    let values = map(values)
    return try order.map { id in
        guard let value = values[id] else { throw WorkSnapshotError.invalidEntityReference }
        return Flag(
            id: FlagID(rawValue: id.rawValue),
            title: value.title,
            note: value.note,
            isResolved: value.isResolved,
            plantedChapterID: value.plantedChapterID.map { ChapterID(rawValue: $0.rawValue) },
            resolvedChapterID: value.resolvedChapterID.map { ChapterID(rawValue: $0.rawValue) }
        )
    }
}

private func materializeWorldNotes(
    order: [WorkStableID],
    values: [WorkWorldNoteSnapshot]
) throws -> [WorldNote] {
    let values = map(values)
    return try order.map { id in
        guard let value = values[id] else { throw WorkSnapshotError.invalidEntityReference }
        return WorldNote(
            id: WorldNoteID(rawValue: id.rawValue),
            title: value.title,
            content: value.content
        )
    }
}
