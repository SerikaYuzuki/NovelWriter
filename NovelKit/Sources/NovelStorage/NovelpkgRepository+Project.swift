import Foundation

extension NovelpkgRepository {
    static func readSynopsis(from packageURL: URL) throws -> String {
        let projectURL = packageURL.appendingPathComponent(projectFileName)
        guard FileManager.default.fileExists(atPath: projectURL.path) else { return "" }

        do {
            let metadata = try JSONDecoder().decode(ProjectMetadata.self, from: Data(contentsOf: projectURL))
            return metadata.synopsis
        } catch {
            throw NovelpkgError.metadataCorrupted(
                url: packageURL,
                file: projectFileName,
                reason: String(describing: error)
            )
        }
    }

    static func writeSynopsis(_ synopsis: String, into workingURL: URL) throws {
        guard !synopsis.isEmpty else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(ProjectMetadata(synopsis: synopsis))
        } catch {
            throw NovelpkgError.saveFailed(reason: String(describing: error))
        }
        try data.write(to: workingURL.appendingPathComponent(projectFileName))
    }
}

private struct ProjectMetadata: Codable {
    let synopsis: String
}
