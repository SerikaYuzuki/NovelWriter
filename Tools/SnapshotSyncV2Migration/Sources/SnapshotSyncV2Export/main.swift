import Foundation
import SnapshotSyncV2Migration

@main
struct SnapshotSyncV2Export {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.count == 3 else {
                throw UsageError()
            }
            let report = try await LegacyV1Exporter().export(
                options: LegacyV1ExportOptions(
                    sourceSQLiteURL: URL(fileURLWithPath: arguments[0]),
                    classificationLedgerURL: URL(fileURLWithPath: arguments[1]),
                    stageRootURL: URL(fileURLWithPath: arguments[2], isDirectory: true)
                )
            )
            let exported = report.entries.filter { $0.outcome == "exported" }.count
            let blocked = report.entries.count - exported
            print("Snapshot Sync v2 legacy export complete: exported=\(exported) blocked=\(blocked) objectIssues=\(report.objectVerificationIssues.count)")
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
    let message = "usage: snapshot-sync-v2-export <legacy-v1.sqlite> <classification.csv> <stage-root>"
}
