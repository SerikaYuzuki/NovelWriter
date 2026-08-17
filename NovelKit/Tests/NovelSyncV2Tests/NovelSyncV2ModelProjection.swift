import Foundation
import NovelCore
@testable import NovelSyncV2

extension NovelSyncV2ConformanceTests {
    func materialized(_ model: SnapshotModel) -> [String: Any] {
        [
            "schemaVersion": 2,
            "workId": model.workId.description,
            "document": materializedDocument(model),
            "attachments": model.attachments.map(materializedAttachment)
        ]
    }

    private func materializedDocument(_ model: SnapshotModel) -> [String: Any] {
        [
            "id": model.document.id.uuidString.lowercased(),
            "documentCreatedAt": isoString(model.documentCreatedAt),
            "title": model.document.title,
            "synopsis": model.document.synopsis,
            "chapters": model.document.chapters.map(materializedChapter),
            "characters": model.document.characters.map(materializedCharacter),
            "plotCards": model.document.plotCards.map(materializedPlotCard),
            "flags": model.document.flags.map(materializedFlag),
            "worldNotes": model.document.worldNotes.map(materializedWorldNote)
        ]
    }

    private func materializedChapter(_ chapter: NovelCore.Chapter) -> [String: Any] {
        [
            "id": chapter.id.rawValue.uuidString.lowercased(),
            "title": chapter.title,
            "episodes": chapter.episodes.map(materializedEpisode)
        ]
    }

    private func materializedEpisode(_ episode: Episode) -> [String: Any] {
        [
            "id": episode.id.rawValue.uuidString.lowercased(),
            "title": episode.title,
            "content": episode.content,
            "memo": episode.memo
        ]
    }

    private func materializedCharacter(_ character: NovelCore.Character) -> [String: Any] {
        [
            "id": character.id.rawValue.uuidString.lowercased(),
            "name": character.name,
            "kana": character.kana,
            "memo": character.memo,
            "colorHex": jsonValue(character.colorHex),
            "role": jsonValue(character.role),
            "age": jsonValue(character.age),
            "gender": jsonValue(character.gender),
            "firstPerson": jsonValue(character.firstPerson),
            "secondPerson": jsonValue(character.secondPerson),
            "speechStyle": jsonValue(character.speechStyle),
            "appearance": jsonValue(character.appearance),
            "personality": jsonValue(character.personality),
            "background": jsonValue(character.background)
        ]
    }

    private func materializedPlotCard(_ card: PlotCard) -> [String: Any] {
        [
            "id": card.id.rawValue.uuidString.lowercased(),
            "title": card.title,
            "memo": card.memo,
            "chapterId": jsonValue(card.chapterID?.rawValue.uuidString.lowercased())
        ]
    }

    private func materializedFlag(_ flag: Flag) -> [String: Any] {
        [
            "id": flag.id.rawValue.uuidString.lowercased(),
            "title": flag.title,
            "note": flag.note,
            "isResolved": flag.isResolved,
            "plantedChapterId": jsonValue(flag.plantedChapterID?.rawValue.uuidString.lowercased()),
            "resolvedChapterId": jsonValue(flag.resolvedChapterID?.rawValue.uuidString.lowercased())
        ]
    }

    private func materializedWorldNote(_ note: WorldNote) -> [String: Any] {
        [
            "id": note.id.rawValue.uuidString.lowercased(),
            "title": note.title,
            "content": note.content
        ]
    }

    private func materializedAttachment(_ attachment: SyncAttachment) -> [String: Any] {
        [
            "attachmentId": attachment.attachmentId.uuidString.lowercased(),
            "fileName": attachment.fileName,
            "byteCount": attachment.byteCount,
            "objectId": attachment.objectId.rawValue
        ]
    }

    private func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [
            .withInternetDateTime,
            .withDashSeparatorInDate,
            .withColonSeparatorInTime
        ]
        return formatter.string(from: date)
    }

    private func jsonValue(_ value: String?) -> Any {
        value ?? NSNull()
    }
}

extension [String: Any] {
    var asNSDictionary: NSDictionary {
        NSDictionary(dictionary: self)
    }
}
