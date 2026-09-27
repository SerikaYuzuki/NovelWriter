import Foundation
import NovelCore

public enum SnapshotCodec {
    public static func encode(
        _ model: SnapshotModel,
        parents: [SnapshotID] = []
    ) throws -> EncodedSnapshot {
        var encoder = SnapshotEncodingContext()
        return try encoder.encode(model, parents: parents)
    }

    public static func decode(
        manifestBytes: Data,
        objects: [ObjectID: Data]
    ) throws -> SnapshotModel {
        var decoder = try SnapshotDecodingContext(
            manifestBytes: manifestBytes,
            objects: objects
        )
        return try decoder.decode()
    }
}
