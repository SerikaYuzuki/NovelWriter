import Foundation
import SnapshotSyncV2Migration

@main
struct SnapshotSyncV2Export {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.count == 6, arguments[0] == "--source-is-verified-archive" else {
                throw UsageError()
            }
            let report = try await LegacyV1Exporter().export(
                options: LegacyV1ExportOptions(
                    sourceSQLiteURL: URL(fileURLWithPath: arguments[1]),
                    classificationLedgerURL: URL(fileURLWithPath: arguments[2]),
                    stageRootURL: URL(fileURLWithPath: arguments[3], isDirectory: true),
                    sourceArchiveRootURL: URL(fileURLWithPath: arguments[4], isDirectory: true),
                    archiveManifestURL: URL(fileURLWithPath: arguments[5]),
                    sourceIsVerifiedArchive: true
                )
            )
            let exported = report.entries.count(where: { $0.outcome == "exported" })
            let blocked = report.entries.count - exported
            print("Snapshot Sync v2 legacy export complete: exported=\(exported) blocked=\(blocked) objectIssues=\(report.objectVerificationIssues.count) sourceRowIssues=\(report.sourceRowIssues.count)")
            if blocked > 0 || !report.objectVerificationIssues.isEmpty || !report.sourceRowIssues.isEmpty {
                exit(2)
            }
        } catch let error as UsageError {
            fputs(error.message + "\n", stderr)
            exit(64)
        } catch {
            fputs("Snapshot Sync v2 legacy export failed: \(error)\n", stderr)
            exit(1)
        }
    }
}

private struct UsageError: Error {
    let message = "usage: snapshot-sync-v2-export --source-is-verified-archive <legacy-v1.sqlite> <classification.csv> <stage-root> <archive-root> <sha256-manifest>"
}
