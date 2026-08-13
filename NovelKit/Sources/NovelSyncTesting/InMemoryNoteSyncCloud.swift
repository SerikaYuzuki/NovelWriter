import NovelSync

public actor InMemoryNoteSyncCloud: NoteSyncCloudStore {
    private var records: [NoteSyncEntityKey: NoteSyncRecord] = [:]

    public init() {}

    public func save(
        _ incoming: [NoteSyncRecord],
        expectedDigests: [NoteSyncEntityKey: SyncContentDigest],
        forceOverwrite: Set<NoteSyncEntityKey>
    ) async throws -> NoteSyncSendResult {
        var result = NoteSyncSendResult()
        for record in incoming {
            if let existing = records[record.key],
               !forceOverwrite.contains(record.key),
               existing.digest != expectedDigests[record.key] {
                result.conflictedKeys.insert(record.key)
                result.conflictedRemoteRecords.append(existing)
                continue
            }
            records[record.key] = record
            result.acceptedSaves.append(record)
        }
        return result
    }

    public func delete(
        _ keys: [NoteSyncEntityKey],
        expectedDigests: [NoteSyncEntityKey: SyncContentDigest],
        forceOverwrite: Set<NoteSyncEntityKey>
    ) async throws -> NoteSyncSendResult {
        var result = NoteSyncSendResult()
        for key in keys {
            if let existing = records[key],
               !forceOverwrite.contains(key),
               existing.digest != expectedDigests[key] {
                result.conflictedKeys.insert(key)
                result.conflictedRemoteRecords.append(existing)
                continue
            }
            records.removeValue(forKey: key)
            result.acceptedDeletes.append(key)
        }
        return result
    }

    public func fetchAll(for workID: SyncWorkID) async throws -> [NoteSyncRecord] {
        records.values.filter { $0.key.workID == workID }.sorted { $0.key < $1.key }
    }

    public func listWorkRecords() async throws -> [NoteSyncRecord] {
        records.values.filter { $0.key.kind == .work }.sorted { $0.key < $1.key }
    }

    public func removeAll() {
        records.removeAll()
    }
}
