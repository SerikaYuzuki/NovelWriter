import Foundation
import NovelCore

public enum NoteSyncProjectionError: Error, Equatable, Sendable {
    case missingWorkRecord
    case duplicateRecord
    case workIDMismatch
    case invalidEntityReference
    case chapterOwnershipMismatch
}

public enum NoteSyncProjection {
    public static func records(workID: SyncWorkID, snapshot: WorkSnapshot) throws -> [NoteSyncRecord] {
        try snapshot.validate()
        let records = try [workRecord(workID: workID, snapshot: snapshot)]
            + chapterRecords(workID: workID, snapshot: snapshot)
            + episodeRecords(workID: workID, snapshot: snapshot)
            + characterRecords(workID: workID, snapshot: snapshot)
            + plotCardRecords(workID: workID, snapshot: snapshot)
            + flagRecords(workID: workID, snapshot: snapshot)
            + worldNoteRecords(workID: workID, snapshot: snapshot)
        return records.sorted { $0.key < $1.key }
    }

    public static func snapshot(workID: SyncWorkID, records: [NoteSyncRecord]) throws -> WorkSnapshot {
        let index = try RecordIndex(workID: workID, records: records)
        return try WorkSnapshot(document: index.materializedDocument())
    }

    public static func changes(
        workID: SyncWorkID,
        from previous: WorkSnapshot,
        to current: WorkSnapshot
    ) throws -> NoteSyncDirtySet {
        let previousRecords = try keyedRecords(records(workID: workID, snapshot: previous), workID: workID)
        let currentRecords = try keyedRecords(records(workID: workID, snapshot: current), workID: workID)
        return NoteSyncDirtySet.difference(from: previousRecords, to: currentRecords)
    }

    public static func remappedRecords(
        _ records: [NoteSyncRecord],
        to workID: SyncWorkID
    ) throws -> [NoteSyncRecord] {
        try records.map { record in
            try NoteSyncRecord(
                key: NoteSyncEntityKey(
                    workID: workID,
                    kind: record.key.kind,
                    entityID: record.key.entityID
                ),
                payload: record.payload
            )
        }.sorted { $0.key < $1.key }
    }

    static func keyedRecords(
        _ records: [NoteSyncRecord],
        workID: SyncWorkID
    ) throws -> [NoteSyncEntityKey: NoteSyncRecord] {
        var keyed: [NoteSyncEntityKey: NoteSyncRecord] = [:]
        for record in records {
            guard record.key.workID == workID else {
                throw NoteSyncProjectionError.workIDMismatch
            }
            if keyed[record.key] != nil {
                throw NoteSyncProjectionError.duplicateRecord
            }
            keyed[record.key] = record
        }
        return keyed
    }

    private static func workRecord(workID: SyncWorkID, snapshot: WorkSnapshot) throws -> NoteSyncRecord {
        try NoteSyncRecord(
            key: .work(workID),
            payload: .work(
                NoteSyncWorkPayload(
                    documentID: snapshot.documentID,
                    title: snapshot.title,
                    synopsis: snapshot.synopsis,
                    chapterOrder: snapshot.chapterOrder,
                    characterOrder: snapshot.characterOrder,
                    plotCardOrder: snapshot.plotCardOrder,
                    flagOrder: snapshot.flagOrder,
                    worldNoteOrder: snapshot.worldNoteOrder
                )
            )
        )
    }

    private static func chapterRecords(workID: SyncWorkID, snapshot: WorkSnapshot) throws -> [NoteSyncRecord] {
        try snapshot.chapters.map { chapter in
            try NoteSyncRecord(
                key: NoteSyncEntityKey(workID: workID, kind: .chapter, entityID: chapter.id),
                payload: .chapter(
                    NoteSyncChapterPayload(title: chapter.title, episodeOrder: chapter.episodeOrder)
                )
            )
        }
    }

    private static func episodeRecords(workID: SyncWorkID, snapshot: WorkSnapshot) throws -> [NoteSyncRecord] {
        let episodeChapter = try episodeOwnership(in: snapshot)
        return try snapshot.episodes.map { episode in
            guard let chapterID = episodeChapter[episode.id] else {
                throw NoteSyncProjectionError.invalidEntityReference
            }
            return try NoteSyncRecord(
                key: NoteSyncEntityKey(workID: workID, kind: .episode, entityID: episode.id),
                payload: .episode(
                    NoteSyncEpisodePayload(
                        chapterID: chapterID,
                        title: episode.title,
                        content: episode.content,
                        memo: episode.memo
                    )
                )
            )
        }
    }

    private static func characterRecords(workID: SyncWorkID, snapshot: WorkSnapshot) throws -> [NoteSyncRecord] {
        try snapshot.characters.map { character in
            try NoteSyncRecord(
                key: NoteSyncEntityKey(workID: workID, kind: .character, entityID: character.id),
                payload: .character(
                    NoteSyncCharacterPayload(
                        name: character.name,
                        kana: character.kana,
                        memo: character.memo,
                        colorHex: character.colorHex,
                        role: character.role,
                        age: character.age,
                        gender: character.gender,
                        firstPerson: character.firstPerson,
                        secondPerson: character.secondPerson,
                        speechStyle: character.speechStyle,
                        appearance: character.appearance,
                        personality: character.personality,
                        background: character.background
                    )
                )
            )
        }
    }

    private static func plotCardRecords(workID: SyncWorkID, snapshot: WorkSnapshot) throws -> [NoteSyncRecord] {
        try snapshot.plotCards.map { card in
            try NoteSyncRecord(
                key: NoteSyncEntityKey(workID: workID, kind: .plotCard, entityID: card.id),
                payload: .plotCard(
                    NoteSyncPlotCardPayload(title: card.title, memo: card.memo, chapterID: card.chapterID)
                )
            )
        }
    }

    private static func flagRecords(workID: SyncWorkID, snapshot: WorkSnapshot) throws -> [NoteSyncRecord] {
        try snapshot.flags.map { flag in
            try NoteSyncRecord(
                key: NoteSyncEntityKey(workID: workID, kind: .flag, entityID: flag.id),
                payload: .flag(
                    NoteSyncFlagPayload(
                        title: flag.title,
                        note: flag.note,
                        isResolved: flag.isResolved,
                        plantedChapterID: flag.plantedChapterID,
                        resolvedChapterID: flag.resolvedChapterID
                    )
                )
            )
        }
    }

    private static func worldNoteRecords(workID: SyncWorkID, snapshot: WorkSnapshot) throws -> [NoteSyncRecord] {
        try snapshot.worldNotes.map { note in
            try NoteSyncRecord(
                key: NoteSyncEntityKey(workID: workID, kind: .worldNote, entityID: note.id),
                payload: .worldNote(NoteSyncWorldNotePayload(title: note.title, content: note.content))
            )
        }
    }

    private static func episodeOwnership(in snapshot: WorkSnapshot) throws -> [WorkStableID: WorkStableID] {
        var ownership: [WorkStableID: WorkStableID] = [:]
        for chapter in snapshot.chapters {
            for episodeID in chapter.episodeOrder {
                if ownership[episodeID] != nil {
                    throw NoteSyncProjectionError.invalidEntityReference
                }
                ownership[episodeID] = chapter.id
            }
        }
        return ownership
    }
}

private struct RecordIndex {
    let work: NoteSyncWorkPayload
    let chapters: [WorkStableID: NoteSyncChapterPayload]
    let episodes: [WorkStableID: NoteSyncEpisodePayload]
    let characters: [WorkStableID: NoteSyncCharacterPayload]
    let plotCards: [WorkStableID: NoteSyncPlotCardPayload]
    let flags: [WorkStableID: NoteSyncFlagPayload]
    let worldNotes: [WorkStableID: NoteSyncWorldNotePayload]

    init(workID: SyncWorkID, records: [NoteSyncRecord]) throws {
        let keyed = try NoteSyncProjection.keyedRecords(records, workID: workID)
        guard let workRecord = keyed[.work(workID)], case let .work(work) = workRecord.payload else {
            throw NoteSyncProjectionError.missingWorkRecord
        }
        self.work = work
        chapters = try Self.payloads(in: keyed, kind: .chapter) { payload in
            guard case let .chapter(value) = payload else {
                throw NoteSyncProjectionError.invalidEntityReference
            }
            return value
        }
        episodes = try Self.payloads(in: keyed, kind: .episode) { payload in
            guard case let .episode(value) = payload else {
                throw NoteSyncProjectionError.invalidEntityReference
            }
            return value
        }
        characters = try Self.payloads(in: keyed, kind: .character) { payload in
            guard case let .character(value) = payload else {
                throw NoteSyncProjectionError.invalidEntityReference
            }
            return value
        }
        plotCards = try Self.payloads(in: keyed, kind: .plotCard) { payload in
            guard case let .plotCard(value) = payload else {
                throw NoteSyncProjectionError.invalidEntityReference
            }
            return value
        }
        flags = try Self.payloads(in: keyed, kind: .flag) { payload in
            guard case let .flag(value) = payload else {
                throw NoteSyncProjectionError.invalidEntityReference
            }
            return value
        }
        worldNotes = try Self.payloads(in: keyed, kind: .worldNote) { payload in
            guard case let .worldNote(value) = payload else {
                throw NoteSyncProjectionError.invalidEntityReference
            }
            return value
        }
    }

    func materializedDocument() throws -> NovelDocument {
        try validateEpisodeReferences()
        return try NovelDocument(
            id: work.documentID.rawValue,
            title: work.title,
            synopsis: work.synopsis,
            chapters: assembledChapters(),
            characters: assembledCharacters(),
            plotCards: assembledPlotCards(),
            flags: assembledFlags(),
            worldNotes: assembledWorldNotes()
        )
    }

    private func validateEpisodeReferences() throws {
        let referencedEpisodes = try work.chapterOrder.flatMap { chapterID -> [WorkStableID] in
            guard let chapter = chapters[chapterID] else {
                throw NoteSyncProjectionError.invalidEntityReference
            }
            return chapter.episodeOrder
        }
        guard Set(referencedEpisodes).count == referencedEpisodes.count,
              Set(referencedEpisodes) == Set(episodes.keys) else {
            throw NoteSyncProjectionError.invalidEntityReference
        }
    }

    private func assembledChapters() throws -> [Chapter] {
        try work.chapterOrder.map { chapterID in
            guard let chapter = chapters[chapterID] else {
                throw NoteSyncProjectionError.invalidEntityReference
            }
            let assembledEpisodes = try chapter.episodeOrder.map { episodeID -> Episode in
                guard let episode = episodes[episodeID] else {
                    throw NoteSyncProjectionError.invalidEntityReference
                }
                guard episode.chapterID == chapterID else {
                    throw NoteSyncProjectionError.chapterOwnershipMismatch
                }
                return Episode(
                    id: EpisodeID(rawValue: episodeID.rawValue),
                    title: episode.title,
                    content: episode.content,
                    memo: episode.memo
                )
            }
            return Chapter(
                id: ChapterID(rawValue: chapterID.rawValue),
                title: chapter.title,
                episodes: assembledEpisodes
            )
        }
    }

    private func assembledCharacters() throws -> [Character] {
        try ordered(work.characterOrder, values: characters).map { id, character in
            Character(
                id: CharacterID(rawValue: id.rawValue),
                name: character.name,
                kana: character.kana,
                memo: character.memo,
                colorHex: character.colorHex,
                role: character.role,
                age: character.age,
                gender: character.gender,
                firstPerson: character.firstPerson,
                secondPerson: character.secondPerson,
                speechStyle: character.speechStyle,
                appearance: character.appearance,
                personality: character.personality,
                background: character.background
            )
        }
    }

    private func assembledPlotCards() throws -> [PlotCard] {
        try ordered(work.plotCardOrder, values: plotCards).map { id, card in
            PlotCard(
                id: PlotCardID(rawValue: id.rawValue),
                title: card.title,
                memo: card.memo,
                chapterID: card.chapterID.map { ChapterID(rawValue: $0.rawValue) }
            )
        }
    }

    private func assembledFlags() throws -> [Flag] {
        try ordered(work.flagOrder, values: flags).map { id, flag in
            Flag(
                id: FlagID(rawValue: id.rawValue),
                title: flag.title,
                note: flag.note,
                isResolved: flag.isResolved,
                plantedChapterID: flag.plantedChapterID.map { ChapterID(rawValue: $0.rawValue) },
                resolvedChapterID: flag.resolvedChapterID.map { ChapterID(rawValue: $0.rawValue) }
            )
        }
    }

    private func assembledWorldNotes() throws -> [WorldNote] {
        try ordered(work.worldNoteOrder, values: worldNotes).map { id, note in
            WorldNote(
                id: WorldNoteID(rawValue: id.rawValue),
                title: note.title,
                content: note.content
            )
        }
    }

    private static func payloads<Value>(
        in keyed: [NoteSyncEntityKey: NoteSyncRecord],
        kind: NoteSyncEntityKind,
        extract: (NoteSyncPayload) throws -> Value
    ) throws -> [WorkStableID: Value] {
        var values: [WorkStableID: Value] = [:]
        for (key, record) in keyed where key.kind == kind {
            if values[key.entityID] != nil {
                throw NoteSyncProjectionError.duplicateRecord
            }
            values[key.entityID] = try extract(record.payload)
        }
        return values
    }

    private func ordered<Value>(
        _ order: [WorkStableID],
        values: [WorkStableID: Value]
    ) throws -> [(WorkStableID, Value)] {
        guard Set(order).count == order.count, Set(order) == Set(values.keys) else {
            throw NoteSyncProjectionError.invalidEntityReference
        }
        return try order.map { id in
            guard let value = values[id] else {
                throw NoteSyncProjectionError.invalidEntityReference
            }
            return (id, value)
        }
    }
}
