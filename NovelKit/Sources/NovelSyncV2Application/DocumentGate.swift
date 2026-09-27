import Foundation
import NovelSyncV2

public struct DocumentSessionToken: Hashable, Sendable {
    public let workID: WorkID
    public let identity: UUID
    public let revision: UInt64

    public init(workID: WorkID, identity: UUID, revision: UInt64) {
        self.workID = workID
        self.identity = identity
        self.revision = revision
    }
}

public struct DocumentGateToken: Hashable, Sendable {
    public let workID: WorkID
    public let sessionIdentity: UUID
    public let gateIdentity: UUID
    public let sessionRevision: UInt64
    public let expectedLocalVersion: SyncV2LocalVersion

    public init(
        workID: WorkID,
        sessionIdentity: UUID,
        gateIdentity: UUID,
        sessionRevision: UInt64,
        expectedLocalVersion: SyncV2LocalVersion
    ) {
        self.workID = workID
        self.sessionIdentity = sessionIdentity
        self.gateIdentity = gateIdentity
        self.sessionRevision = sessionRevision
        self.expectedLocalVersion = expectedLocalVersion
    }
}

public struct SyncV2LocalVersion: Hashable, Sendable {
    public let generation: Int64
    public let snapshotID: SnapshotID?

    public init(generation: Int64, snapshotID: SnapshotID?) {
        self.generation = generation
        self.snapshotID = snapshotID
    }
}

public struct SyncV2SafeBoundaryProof: Hashable, Sendable {
    public let editorGeneration: UInt64
    public let hasMarkedText: Bool
    public let hasUnsavedChanges: Bool
    public let pendingIntentCleared: Bool

    public init(
        editorGeneration: UInt64,
        hasMarkedText: Bool,
        hasUnsavedChanges: Bool,
        pendingIntentCleared: Bool
    ) {
        self.editorGeneration = editorGeneration
        self.hasMarkedText = hasMarkedText
        self.hasUnsavedChanges = hasUnsavedChanges
        self.pendingIntentCleared = pendingIntentCleared
    }
}

public protocol SyncV2ArmableDocumentGate: SyncV2DocumentGate {
    func arm(
        session: DocumentSessionToken,
        expectedLocalVersion: SyncV2LocalVersion,
        proof: SyncV2SafeBoundaryProof
    ) async throws
}

public struct SafeAdoptionBoundary: Hashable, Sendable {
    public let workID: WorkID
    public let inboxID: UUID
    public let session: DocumentSessionToken
    public let gate: DocumentGateToken

    public init(
        workID: WorkID,
        inboxID: UUID,
        session: DocumentSessionToken,
        gate: DocumentGateToken
    ) {
        self.workID = workID
        self.inboxID = inboxID
        self.session = session
        self.gate = gate
    }
}

public struct SyncV2AdoptionTransaction: Hashable, Sendable {
    public let boundary: SafeAdoptionBoundary
    public let requireNoPendingIntent: Bool

    public init(
        boundary: SafeAdoptionBoundary,
        requireNoPendingIntent: Bool = true
    ) {
        self.boundary = boundary
        self.requireNoPendingIntent = requireNoPendingIntent
    }
}

public protocol SyncV2DocumentGate: Sendable {
    func beginSession(workID: WorkID) async -> DocumentSessionToken
    func issueToken(
        for session: DocumentSessionToken,
        expectedLocalVersion: SyncV2LocalVersion
    ) async throws -> DocumentGateToken
    func validateAndConsume(
        _ gate: DocumentGateToken,
        session: DocumentSessionToken
    ) async -> Bool
}

public actor InMemorySyncV2DocumentGate: SyncV2DocumentGate {
    private var revisions: [WorkID: UInt64] = [:]
    private var sessions: [WorkID: DocumentSessionToken] = [:]
    private var issued: Set<UUID> = []
    private var unsafeWorks: Set<WorkID> = []

    public init() {}

    public func beginSession(workID: WorkID) -> DocumentSessionToken {
        let revision = (revisions[workID] ?? 0) + 1
        revisions[workID] = revision
        let session = DocumentSessionToken(
            workID: workID,
            identity: UUID(),
            revision: revision
        )
        sessions[workID] = session
        return session
    }

    public func issueToken(
        for session: DocumentSessionToken,
        expectedLocalVersion: SyncV2LocalVersion
    ) throws -> DocumentGateToken {
        guard sessions[session.workID] == session,
              !unsafeWorks.contains(session.workID) else {
            throw SyncV2ApplicationError.safeBoundaryRejected
        }
        let identity = UUID()
        issued.insert(identity)
        return DocumentGateToken(
            workID: session.workID,
            sessionIdentity: session.identity,
            gateIdentity: identity,
            sessionRevision: session.revision,
            expectedLocalVersion: expectedLocalVersion
        )
    }

    public func validateAndConsume(
        _ gate: DocumentGateToken,
        session: DocumentSessionToken
    ) -> Bool {
        guard sessions[session.workID] == session,
              gate.workID == session.workID,
              gate.sessionIdentity == session.identity,
              gate.sessionRevision == session.revision,
              issued.remove(gate.gateIdentity) != nil else {
            return false
        }
        return true
    }

    public func setUnsafe(_ unsafe: Bool, workID: WorkID) {
        if unsafe {
            unsafeWorks.insert(workID)
        } else {
            unsafeWorks.remove(workID)
        }
    }
}
