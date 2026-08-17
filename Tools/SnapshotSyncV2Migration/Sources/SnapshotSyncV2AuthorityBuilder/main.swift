import Foundation
import SnapshotSyncV2MigrationCore

@main
struct SnapshotSyncV2AuthorityBuilderCLI {
    static func main() async {
        do {
            let options = try parse(CommandLine.arguments.dropFirst())
            let result = try await TrustedProvenanceBuilder().build(options)
            let output: [String: Any] = [
                "authorityID": result.authorityID,
                "authorityDigest": result.authorityDigest,
                "authorityURL": result.authorityURL.path
            ]
            try FileHandle.standardOutput.write(JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .withoutEscapingSlashes]))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            fputs("authority build failed: \(error)\n", stderr)
            exit(2)
        }
    }

    private static func parse(_ args: ArraySlice<String>) throws -> TrustedProvenanceBuilderOptions {
        var values: [String: String] = [:]
        var index = args.startIndex
        while index < args.endIndex {
            guard args[index].hasPrefix("--"), index < args.index(before: args.endIndex) else {
                throw TrustedProvenanceBuilderError.invalidArgument("arguments")
            }
            let key = String(args[index].dropFirst(2))
            let next = args.index(after: index)
            values[key] = args[next]
            index = args.index(after: next)
        }
        guard let stage = values["stage-root"],
              let classification = values["classification"],
              let archiveRoot = values["archive-root"],
              let manifest = values["archive-manifest"],
              let sqlite = values["source-sqlite"],
              let expectedClassification = values["expected-classification-digest"],
              let expectedSQLite = values["expected-source-sqlite-digest"],
              let expectedManifest = values["expected-archive-manifest-digest"],
              let count = values["expected-work-count"].flatMap(Int.init),
              let authorityID = values["authority-id"],
              let output = values["authority-root"] else {
            throw TrustedProvenanceBuilderError.invalidArgument("requiredArguments")
        }
        return TrustedProvenanceBuilderOptions(
            stageRootURL: URL(fileURLWithPath: stage, isDirectory: true),
            classificationLedgerURL: URL(fileURLWithPath: classification),
            sourceArchiveRootURL: URL(fileURLWithPath: archiveRoot, isDirectory: true),
            archiveManifestURL: URL(fileURLWithPath: manifest),
            sourceSQLiteURL: URL(fileURLWithPath: sqlite),
            expectedClassificationDigest: expectedClassification,
            expectedSourceSQLiteDigest: expectedSQLite,
            expectedArchiveManifestDigest: expectedManifest,
            expectedWorkCount: count,
            authorityID: authorityID,
            outputRootURL: URL(fileURLWithPath: output, isDirectory: true)
        )
    }
}
