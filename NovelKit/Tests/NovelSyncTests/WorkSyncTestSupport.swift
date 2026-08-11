import Foundation
import NovelCore
import NovelSync
import NovelSyncTesting
import Testing

enum WorkTestValues {
    static let workID = SyncWorkID(rawValue: uuid("A0000000-0000-0000-0000-000000000001"))
    static let copyA = LocalWorkingCopyID(rawValue: uuid("A0000000-0000-0000-0000-000000000002"))
    static let copyB = LocalWorkingCopyID(rawValue: uuid("A0000000-0000-0000-0000-000000000003"))
    static let replicaA = SyncReplicaID(rawValue: uuid("A0000000-0000-0000-0000-000000000004"))
    static let replicaB = SyncReplicaID(rawValue: uuid("A0000000-0000-0000-0000-000000000005"))
    static let sessionA = SyncEditSessionID(rawValue: uuid("A0000000-0000-0000-0000-000000000006"))
    static let sessionB = SyncEditSessionID(rawValue: uuid("A0000000-0000-0000-0000-000000000007"))
    static let branch = SyncBranchID(rawValue: uuid("A0000000-0000-0000-0000-000000000008"))
    static let date = Date(timeIntervalSince1970: 1_786_425_600)

    static let documentID = uuid("D0000000-0000-0000-0000-000000000001")
    static let chapter1 = ChapterID(rawValue: uuid("10000000-0000-0000-0000-000000000001"))
    static let chapter2 = ChapterID(rawValue: uuid("10000000-0000-0000-0000-000000000002"))
    static let chapter3 = ChapterID(rawValue: uuid("10000000-0000-0000-0000-000000000003"))
    static let episode1 = EpisodeID(rawValue: uuid("20000000-0000-0000-0000-000000000001"))
    static let episode2 = EpisodeID(rawValue: uuid("20000000-0000-0000-0000-000000000002"))
    static let character1 = CharacterID(rawValue: uuid("30000000-0000-0000-0000-000000000001"))
    static let character2 = CharacterID(rawValue: uuid("30000000-0000-0000-0000-000000000002"))
    static let character3 = CharacterID(rawValue: uuid("30000000-0000-0000-0000-000000000003"))
    static let plot1 = PlotCardID(rawValue: uuid("40000000-0000-0000-0000-000000000001"))
    static let flag1 = FlagID(rawValue: uuid("50000000-0000-0000-0000-000000000001"))
    static let world1 = WorldNoteID(rawValue: uuid("60000000-0000-0000-0000-000000000001"))

    static func fullDocument() -> NovelDocument {
        NovelDocument(
            id: documentID,
            title: "銀河鉄道",
            synopsis: "始まり\n中盤\n終わり",
            chapters: [
                Chapter(
                    id: chapter1,
                    title: "第一章",
                    episodes: [
                        Episode(id: episode1, title: "出発", content: "one\ntwo\nthree", memo: "話メモ"),
                        Episode(id: episode2, title: "途中", content: "本文2", memo: "メモ2")
                    ]
                ),
                Chapter(id: chapter2, title: "第二章", episodes: []),
                Chapter(id: chapter3, title: "第三章", episodes: [])
            ],
            characters: [
                Character(
                    id: character1,
                    name: "葵",
                    kana: "あおい",
                    memo: "主人公メモ",
                    colorHex: "#123456",
                    role: "主人公",
                    age: "17",
                    gender: "女",
                    firstPerson: "私",
                    secondPerson: "あなた",
                    speechStyle: "静か",
                    appearance: "黒髪",
                    personality: "慎重",
                    background: "地球出身"
                ),
                Character(id: character2, name: "蓮"),
                Character(id: character3, name: "凪")
            ],
            plotCards: [PlotCard(id: plot1, title: "転換", memo: "構成メモ", chapterID: chapter1)],
            flags: [
                Flag(
                    id: flag1,
                    title: "懐中時計",
                    note: "伏線本文",
                    isResolved: false,
                    plantedChapterID: chapter1,
                    resolvedChapterID: chapter3
                )
            ],
            worldNotes: [WorldNote(id: world1, title: "宇宙港", content: "世界観本文")]
        )
    }

    static func snapshot(_ mutate: (inout NovelDocument) -> Void = { _ in }) throws -> WorkSnapshot {
        var document = fullDocument()
        mutate(&document)
        return try WorkSnapshot(document: document)
    }

    static func revision(
        snapshot: WorkSnapshot,
        id: String,
        parents: [SyncRevisionID] = [],
        replica: SyncReplicaID = replicaA,
        session: SyncEditSessionID = sessionA,
        dateOffset: TimeInterval = 0
    ) throws -> WorkRevision {
        try WorkRevision(
            workID: workID,
            revisionID: SyncRevisionID(rawValue: uuid(id)),
            parentRevisionIDs: parents,
            branchID: branch,
            authorReplicaID: replica,
            authorSessionID: session,
            snapshot: snapshot,
            clientCreatedAt: date.addingTimeInterval(dateOffset)
        )
    }

    static func coordinator(
        server: InMemoryWorkSyncServer,
        journal: some WorkSyncJournal,
        copy: LocalWorkingCopyID = copyA,
        replica: SyncReplicaID = replicaA,
        session: SyncEditSessionID = sessionA
    ) -> WorkSyncCoordinator {
        WorkSyncCoordinator(
            workID: workID,
            localWorkingCopyID: copy,
            replicaID: replica,
            sessionID: session,
            transport: server,
            journal: journal
        )
    }

    private static func uuid(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }
}

@discardableResult
func stageAndConfirm(
    _ coordinator: WorkSyncCoordinator,
    snapshot: WorkSnapshot,
    at date: Date
) async throws -> WorkRevision {
    let revision = try await coordinator.stageLocalSnapshot(snapshot, at: date)
    try await coordinator.confirmLocalSnapshotMaterialized(
        revision.revisionID,
        packageSnapshot: snapshot
    )
    return revision
}

func waitUntil(
    _ predicate: @escaping @Sendable () async -> Bool,
    attempts: Int = 2000
) async -> Bool {
    for _ in 0 ..< attempts {
        if await predicate() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return false
}
