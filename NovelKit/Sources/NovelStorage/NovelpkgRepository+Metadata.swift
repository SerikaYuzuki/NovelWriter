import Foundation
import NovelCore

extension NovelpkgRepository {
    static func readCharacters(from packageURL: URL) throws -> [NovelCore.Character] {
        let charactersURL = packageURL.appendingPathComponent("characters.json")
        guard FileManager.default.fileExists(atPath: charactersURL.path) else { return [] }

        do {
            let data = try Data(contentsOf: charactersURL)
            return try JSONDecoder().decode([NovelCore.Character].self, from: data)
        } catch {
            throw NovelpkgError.manifestCorrupted(url: packageURL, reason: String(describing: error))
        }
    }

    static func readPlotCards(from packageURL: URL, validChapterIDs: Set<ChapterID>) throws -> [PlotCard] {
        let plotURL = packageURL.appendingPathComponent("plot.json")
        guard FileManager.default.fileExists(atPath: plotURL.path) else { return [] }

        do {
            let data = try Data(contentsOf: plotURL)
            let cards = try JSONDecoder().decode([PlotCard].self, from: data)
            return cards.map { card in
                guard let chapterID = card.chapterID, !validChapterIDs.contains(chapterID) else {
                    return card
                }

                var corrected = card
                corrected.chapterID = nil
                return corrected
            }
        } catch {
            throw NovelpkgError.manifestCorrupted(url: packageURL, reason: String(describing: error))
        }
    }

    static func readFlags(from packageURL: URL, validChapterIDs: Set<ChapterID>) throws -> [Flag] {
        let flagsURL = packageURL.appendingPathComponent("flags.json")
        guard FileManager.default.fileExists(atPath: flagsURL.path) else { return [] }

        do {
            let data = try Data(contentsOf: flagsURL)
            let flags = try JSONDecoder().decode([Flag].self, from: data)
            return flags.map { flag in
                var corrected = flag
                if let chapterID = corrected.plantedChapterID, !validChapterIDs.contains(chapterID) {
                    corrected.plantedChapterID = nil
                }
                if let chapterID = corrected.resolvedChapterID, !validChapterIDs.contains(chapterID) {
                    corrected.resolvedChapterID = nil
                }
                return corrected
            }
        } catch {
            throw NovelpkgError.manifestCorrupted(url: packageURL, reason: String(describing: error))
        }
    }

    static func writeCharacters(_ characters: [NovelCore.Character], into workingURL: URL) throws {
        let charactersURL = workingURL.appendingPathComponent("characters.json")
        try encodePrettyJSON(characters).write(to: charactersURL)
    }

    static func writePlotCards(_ cards: [PlotCard], into workingURL: URL) throws {
        let plotURL = workingURL.appendingPathComponent("plot.json")
        try encodePrettyJSON(cards).write(to: plotURL)
    }

    static func writeFlags(_ flags: [Flag], into workingURL: URL) throws {
        let flagsURL = workingURL.appendingPathComponent("flags.json")
        try encodePrettyJSON(flags).write(to: flagsURL)
    }

    private static func encodePrettyJSON(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            return try encoder.encode(value)
        } catch {
            throw NovelpkgError.saveFailed(reason: String(describing: error))
        }
    }
}
