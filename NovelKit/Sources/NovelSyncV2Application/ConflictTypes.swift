import Foundation
import NovelSyncV2

public enum SyncV2ConflictChoice: String, Codable, Equatable, Sendable {
    case useDevice
    case useServer
    case keepBoth
}

public struct SyncV2ConflictAction: Hashable, Sendable {
    public let workID: WorkID
    public let conflictID: UUID
    public let revision: Int64
    public let baseSnapshotID: SnapshotID?
    public let localSnapshotID: SnapshotID
    public let remoteSnapshotID: SnapshotID
    public let sourceGeneration: Int64
    public let choice: SyncV2ConflictChoice
    public let commandID: UUID?
    public let inboxID: UUID?
    public let newWorkID: WorkID?
    public let newDocumentID: DocumentID?

    public init(
        workID: WorkID,
        conflictID: UUID,
        revision: Int64,
        baseSnapshotID: SnapshotID?,
        localSnapshotID: SnapshotID,
        remoteSnapshotID: SnapshotID,
        sourceGeneration: Int64,
        choice: SyncV2ConflictChoice,
        commandID: UUID? = nil,
        inboxID: UUID? = nil,
        newWorkID: WorkID? = nil,
        newDocumentID: DocumentID? = nil
    ) {
        self.workID = workID
        self.conflictID = conflictID
        self.revision = revision
        self.baseSnapshotID = baseSnapshotID
        self.localSnapshotID = localSnapshotID
        self.remoteSnapshotID = remoteSnapshotID
        self.sourceGeneration = sourceGeneration
        self.choice = choice
        self.commandID = commandID
        self.inboxID = inboxID
        self.newWorkID = newWorkID
        self.newDocumentID = newDocumentID
    }
}

public struct SyncV2ConflictProjection: Hashable, Sendable {
    public let conflictID: UUID
    public let revision: Int64
    public let baseSnapshotID: SnapshotID?
    public let localSnapshotID: SnapshotID
    public let remoteSnapshotID: SnapshotID
    public let sourceGeneration: Int64
    public let commandID: UUID?

    public init(
        conflictID: UUID,
        revision: Int64,
        baseSnapshotID: SnapshotID?,
        localSnapshotID: SnapshotID,
        remoteSnapshotID: SnapshotID,
        sourceGeneration: Int64,
        commandID: UUID? = nil
    ) {
        self.conflictID = conflictID
        self.revision = revision
        self.baseSnapshotID = baseSnapshotID
        self.localSnapshotID = localSnapshotID
        self.remoteSnapshotID = remoteSnapshotID
        self.sourceGeneration = sourceGeneration
        self.commandID = commandID
    }
}
