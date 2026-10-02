import Foundation

public extension SnapshotValidator {
    /// Full entity and per-snapshot reference validation with call-local caches.
    /// No model is constructed for every historical revision. Bytes are hashed
    /// once per identity, entity schemas once per (key, identity), and structural
    /// fields are parsed once. A cache never trusts a second, different payload
    /// claiming the same identity. Parent/DAG/work-anchor checks belong to caller.
    static func validateGraphObjects(_ snapshots: [EncodedSnapshot]) throws {
        var objects: [ObjectID: Data] = [:]
        var entities = Set<SnapshotEntry>()
        var fields: [ObjectID: [String: CanonicalJSON.Value]] = [:]
        for snapshot in snapshots {
            try Task.checkCancellation()
            guard try validate(manifestBytes: snapshot.manifestBytes) == snapshot.manifest else {
                throw SyncV2TypeError.invalidManifest
            }
            for entry in snapshot.manifest.entries {
                guard let bytes = snapshot.objects[entry.objectId] else {
                    throw SyncV2TypeError.missingEntity(entry.entityKey)
                }
                guard bytes.count == entry.byteCount else { throw SyncV2TypeError.byteCountMismatch }
                if let existing = objects[entry.objectId] {
                    guard existing == bytes else { throw SyncV2TypeError.digestMismatch }
                } else {
                    guard ObjectID(data: bytes) == entry.objectId else { throw SyncV2TypeError.digestMismatch }
                    objects[entry.objectId] = bytes
                }
                if entry.contentType == .entityJSON, entities.insert(entry).inserted {
                    fields[entry.objectId] = try validateEntity(bytes, for: entry.entityKey)
                }
            }
            var closure = SnapshotClosureValidator(manifest: snapshot.manifest,
                                                   objects: snapshot.objects, validatedFields: fields)
            try closure.validate()
        }
    }
}
