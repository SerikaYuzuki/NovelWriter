import Foundation
import NovelAuth
import NovelSyncV2
import NovelSyncV2Application

extension ProductionSyncV2RemoteClient {
    /// Cursors remain opaque scheduling tokens, but their closed kind/scope
    /// must match the request before any page is persisted or followed.
    nonisolated static func validateModeCursor(_ raw: String?, mode: String, workID: WorkID,
                                               root: SnapshotID, session: FuminiwaSession) throws -> SnapshotID? {
        guard let raw else { return nil }
        guard !raw.isEmpty, raw.utf8.count <= 2048, let bytes = Data(base64URL: raw) else {
            throw SyncV2Failure.quarantined(.invalidRemoteData)
        }
        do {
            let common: Set = ["kind", "accountId", "accountFence", "serverInstanceId", "protocolEpoch", "workId", "snapshotId"]
            let extra: Set<String> = mode == "head" ? ["afterKind", "afterId"] : ["afterDepth", "afterSnapshotId", "afterItem"]
            guard let value = try CanonicalJSON.parseObject(bytes).objectDictionary,
                  Set(value.keys) == common.union(extra), value["kind"]?.stringContents == mode,
                  value["accountId"]?.stringContents == session.accountID,
                  value["accountFence"]?.stringContents == session.accountFence,
                  value["serverInstanceId"]?.stringContents == session.serverInstanceID.uuidString.lowercased(),
                  case .number(2) = value["protocolEpoch"],
                  value["workId"]?.stringContents == workID.description,
                  value["snapshotId"]?.stringContents == root.rawValue else {
                throw SyncV2Failure.quarantined(.invalidRemoteData)
            }
            if mode == "head" {
                guard case let .number(kind) = value["afterKind"], (0 ... 1).contains(kind),
                      let id = value["afterId"]?.stringContents else { throw SyncV2Failure.quarantined(.invalidRemoteData) }
                _ = try ObjectID(rawValue: id)
                return nil
            }
            guard case let .number(depth) = value["afterDepth"], depth >= 0,
                  case let .number(item) = value["afterItem"], item >= 0,
                  let id = value["afterSnapshotId"]?.stringContents else { throw SyncV2Failure.quarantined(.invalidRemoteData) }
            return try SnapshotID(rawValue: id)
        } catch { throw SyncV2Failure.quarantined(.invalidRemoteData) }
    }
}
