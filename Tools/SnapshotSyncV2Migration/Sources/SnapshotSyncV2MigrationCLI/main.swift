import Foundation
import NovelSyncV2
import NovelSyncV2Store
import SnapshotSyncV2MigrationCore

@main
struct SnapshotSyncV2MigrationCLI {
    static func main() async {
        do {
            let options = try parse(CommandLine.arguments.dropFirst())
            let result = try await MigrationRunner().run(options)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            if let inventoryPath = value(CommandLine.arguments.dropFirst(), key: "inventory-file") {
                try encoder.encode(result.inventory).write(to: URL(fileURLWithPath: inventoryPath), options: .withoutOverwriting)
            }
            let output: [String: Any] = [
                "sourceDigest": result.inventory.sourceDigest,
                "workID": result.inventory.workID,
                "documentID": result.inventory.documentID,
                "createdAt": result.inventory.createdAt,
                "fileCount": result.inventory.fileCount,
                "byteCount": result.inventory.byteCount,
                "portableResourceCount": result.inventory.portableResources.count,
                "state": result.state?.rawValue ?? NSNull(),
                "noChanges": result.noChanges,
                "quarantineReason": result.quarantineReason ?? NSNull()
            ]
            try FileHandle.standardOutput.write(JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .withoutEscapingSlashes]))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            fputs("migration failed: \(error)\n", stderr)
            exit(2)
        }
    }

    private static func parse(_ args: ArraySlice<String>) throws -> MigrationOptions {
        var values: [String: String] = [:]
        var commit = false
        var index = args.startIndex
        while index < args.endIndex {
            let value = args[index]
            if value == "--commit" {
                commit = true; index = args.index(after: index); continue
            }
            if value == "--resume" {
                values["resume"] = "true"; index = args.index(after: index); continue
            }
            guard value.hasPrefix("--"), index < args.index(before: args.endIndex) else { throw MigrationError.invalidTarget("arguments") }
            let key = String(value.dropFirst(2))
            let next = args.index(after: index)
            values[key] = args[next]
            index = args.index(after: next)
        }
        guard let source = values["source"], let target = values["target"] else {
            throw MigrationError.invalidTarget("--source and --target are required")
        }
        let workID = try values["work-id"].map(WorkID.init(uuidString:))
        let account: MigrationAccountBinding? = if let bindingPath = values["binding-file"] {
            try readBinding(URL(fileURLWithPath: bindingPath))
        } else {
            nil
        }
        return MigrationOptions(sourceURL: URL(fileURLWithPath: source), targetRoot: URL(fileURLWithPath: target), commit: commit, expectedSourceDigest: values["expected-source-digest"], verifiedMarker: values["verified-marker"], account: account, workID: workID, resume: values["resume"] == "true")
    }

    private static func readBinding(_ url: URL) throws -> MigrationAccountBinding {
        guard FileManager.default.fileExists(atPath: url.path),
              url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let mode = attributes[.posixPermissions] as? NSNumber,
              mode.intValue & 0o077 == 0 else { throw MigrationError.invalidBindingFile }
        let data = try Data(contentsOf: url)
        struct BindingFile: Decodable { let accountID: String; let accountFence: String; let serverInstanceID: String; let protocolEpoch: Int64?; let knownAccountIDs: [String]? }
        let value = try JSONDecoder().decode(BindingFile.self, from: data)
        guard !value.accountID.isEmpty, !value.accountFence.isEmpty, !value.serverInstanceID.isEmpty else { throw MigrationError.invalidBindingFile }
        return MigrationAccountBinding(binding: V2AccountBinding(accountID: value.accountID, accountFence: value.accountFence, serverInstanceID: value.serverInstanceID, protocolEpoch: value.protocolEpoch ?? 2), knownAccountIDs: Set(value.knownAccountIDs ?? [value.accountID]))
    }

    private static func value(_ args: ArraySlice<String>, key: String) -> String? {
        guard let index = args.firstIndex(of: "--\(key)"), args.index(after: index) < args.endIndex else { return nil }
        return args[args.index(after: index)]
    }
}
