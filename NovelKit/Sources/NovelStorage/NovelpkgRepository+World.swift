import Foundation
import NovelCore

extension NovelpkgRepository {
    static func readWorldNotes(from packageURL: URL) throws -> [WorldNote] {
        let worldURL = packageURL.appendingPathComponent(worldFileName)
        guard FileManager.default.fileExists(atPath: worldURL.path) else { return [] }

        let metadata: WorldMetadata
        do {
            metadata = try JSONDecoder().decode(WorldMetadata.self, from: Data(contentsOf: worldURL))
        } catch {
            throw NovelpkgError.metadataCorrupted(
                url: packageURL,
                file: worldFileName,
                reason: String(describing: error)
            )
        }

        let notesURL = packageURL.appendingPathComponent(worldNotesDirectoryName, isDirectory: true)
        return metadata.notes.map { entry in
            let contentURL = notesURL.appendingPathComponent("\(entry.id.uuidString).md")
            let content = (try? String(contentsOf: contentURL, encoding: .utf8)) ?? ""
            return WorldNote(id: WorldNoteID(rawValue: entry.id), title: entry.title, content: content)
        }
    }

    static func writeWorldNotes(
        _ notes: [WorldNote],
        into workingURL: URL,
        fileManager: FileManager
    ) throws {
        guard !notes.isEmpty else { return }

        let notesURL = workingURL.appendingPathComponent(worldNotesDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: notesURL, withIntermediateDirectories: true)
        for note in notes {
            let contentURL = notesURL.appendingPathComponent("\(note.id.rawValue.uuidString).md")
            try note.content.write(to: contentURL, atomically: false, encoding: .utf8)
        }

        let metadata = WorldMetadata(notes: notes.map {
            WorldMetadata.Entry(id: $0.id.rawValue, title: $0.title)
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(metadata)
        } catch {
            throw NovelpkgError.saveFailed(reason: String(describing: error))
        }
        try data.write(to: workingURL.appendingPathComponent(worldFileName))
    }
}

private struct WorldMetadata: Codable {
    struct Entry: Codable {
        let id: UUID
        let title: String
    }

    let notes: [Entry]
}
