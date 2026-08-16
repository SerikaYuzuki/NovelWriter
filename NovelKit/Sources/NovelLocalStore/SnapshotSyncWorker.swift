import Foundation
import NovelAuth

public struct RemoteSnapshotHead: Codable, Equatable, Sendable {
    public let generation: UInt64
    public let snapshotID: String

    public init(generation: UInt64, snapshotID: String) {
        self.generation = generation
        self.snapshotID = snapshotID
    }

    private enum CodingKeys: String, CodingKey {
        case generation
        case snapshotID = "snapshot_id"
    }
}

/// Remote catalog data used only to discover works that are not yet present
/// in this device's SQLite store. The head remains the only sync authority.
public struct SnapshotSyncLibraryEntry: Codable, Equatable, Sendable, Identifiable {
    public let workID: UUID
    public let title: String
    public let head: RemoteSnapshotHead?

    public var id: UUID {
        workID
    }

    private enum CodingKeys: String, CodingKey {
        case workID = "workId"
        case title
        case head
    }
}

public struct RemoteSnapshotPayload: Equatable, Sendable {
    public let workID: UUID
    public let snapshotID: String
    public let parentSnapshotIDs: [String]
    public let manifest: Data
    public let objects: [LocalObject]

    public init(
        workID: UUID,
        snapshotID: String,
        parentSnapshotIDs: [String],
        manifest: Data,
        objects: [LocalObject]
    ) {
        self.workID = workID
        self.snapshotID = snapshotID
        self.parentSnapshotIDs = parentSnapshotIDs
        self.manifest = manifest
        self.objects = objects
    }

    /// Returns the object referenced by a manifest entry. The server does not
    /// promise JSON entry order, so callers must select by the stable entity
    /// key rather than assuming `objects.first` is the document.
    public func object(forEntityKey entityKey: String) -> LocalObject? {
        guard
            let root = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
            let entries = root["entries"] as? [[String: Any]],
            let objectID = entries.first(where: { $0["entityKey"] as? String == entityKey })?["objectId"] as? String else {
            return nil
        }
        return objects.first { $0.objectID == objectID }
    }
}

/// A server-persisted divergence that requires an explicit user choice.
/// Snapshot IDs are retained so the eventual resolver can compare immutable
/// branches without guessing which side should win.
public struct SnapshotSyncConflict: Codable, Equatable, Sendable, Identifiable {
    public let conflictID: UUID
    public let workID: UUID
    public let baseSnapshotID: String?
    public let localSnapshotID: String
    public let remoteSnapshotID: String
    public let state: String
    public let createdAt: String

    public var id: UUID {
        conflictID
    }

    private enum CodingKeys: String, CodingKey {
        case conflictID = "conflict_id"
        case workID = "work_id"
        case baseSnapshotID = "base_snapshot_id"
        case localSnapshotID = "local_snapshot_id"
        case remoteSnapshotID = "remote_snapshot_id"
        case state
        case createdAt = "created_at"
    }
}

public enum SnapshotSyncConflictChoice: String, Codable, Sendable {
    case useThisDevice
    case useServer = "useOnline"
    case keepBoth = "keepBothAsSeparateWorks"
}

public enum SnapshotSyncOutcome: Equatable, Sendable {
    case notStarted
    case offline
    case idle
    case uploaded(snapshotID: String, generation: UInt64)
    case needsChoice(snapshotID: String)
}

public enum SnapshotSyncError: Error, Equatable, Sendable {
    case invalidManifest
    case transport(String)
    case offline
    case unauthorized
    case conflict
}

public protocol SnapshotSyncTransport: Sendable {
    func library(accessToken: String) async throws -> [SnapshotSyncLibraryEntry]
    func snapshotManifest(workID: UUID, snapshotID: String, accessToken: String) async throws -> Data
    func downloadObject(objectID: String, accessToken: String) async throws -> Data
    func uploadObject(objectID: String, bytes: Data, accessToken: String) async throws
    func registerSnapshot(workID: UUID, snapshotID: String, manifest: Data, accessToken: String) async throws
    func head(workID: UUID, accessToken: String) async throws -> RemoteSnapshotHead?
    func publish(
        workID: UUID,
        operationID: UUID,
        expectedHead: RemoteSnapshotHead?,
        candidateSnapshotID: String,
        accessToken: String
    ) async throws -> RemoteSnapshotHead
    func conflicts(workID: UUID, accessToken: String) async throws -> [SnapshotSyncConflict]
    func resolveConflict(
        workID: UUID,
        conflictID: UUID,
        choice: SnapshotSyncConflictChoice,
        expectedRemoteSnapshotID: String,
        accessToken: String
    ) async throws
}

/// Replays durable intents after connectivity returns. Local commit never
/// calls this actor synchronously; a failed network attempt leaves SQLite
/// unchanged and is retried at the next lifecycle/online trigger.
public actor LocalSnapshotSyncWorker {
    private let store: LocalSQLiteStore
    private let transport: any SnapshotSyncTransport
    private let sessionProvider: @Sendable () async throws -> FuminiwaSession?

    public init(
        store: LocalSQLiteStore,
        transport: any SnapshotSyncTransport,
        sessionProvider: @escaping @Sendable () async throws -> FuminiwaSession?
    ) {
        self.store = store
        self.transport = transport
        self.sessionProvider = sessionProvider
    }

    public func sync(workID: UUID) async throws -> SnapshotSyncOutcome {
        let maybeSession: FuminiwaSession?
        do {
            maybeSession = try await sessionProvider()
        } catch {
            return .offline
        }
        guard let session = maybeSession else {
            return .offline
        }
        let intents = try await store.pendingIntents(for: workID)
        guard !intents.isEmpty else { return .idle }
        var latestOutcome: SnapshotSyncOutcome = .idle
        for intent in intents {
            guard let snapshot = try await store.snapshot(id: intent.localSnapshotID) else {
                throw SnapshotSyncError.transport("missing local snapshot \(intent.localSnapshotID)")
            }
            // Offline edits can coalesce the outbox to a leaf whose local
            // parent has never reached the server. Register the complete
            // parent chain first so the server's lineage validation does not
            // turn a normal reconnect into a false sync failure.
            _ = try await ensureSnapshotChain(
                snapshot,
                workID: workID,
                accessToken: session.accessToken,
                visited: []
            )
            let state = try await store.workState(for: workID)
            let expectedHead = intent.expectedHeadSnapshotID.map {
                RemoteSnapshotHead(
                    // A changed acknowledged ID is intentionally represented
                    // with a stale generation; CAS then returns a conflict.
                    generation: state?.acknowledgedHeadSnapshotID == $0
                        ? state?.acknowledgedHeadGeneration ?? 0
                        : 0,
                    snapshotID: $0
                )
            }
            do {
                let remoteHead = try await transport.publish(
                    workID: workID,
                    operationID: intent.id,
                    expectedHead: expectedHead,
                    candidateSnapshotID: snapshot.id,
                    accessToken: session.accessToken
                )
                _ = try await store.acknowledge(
                    intentID: intent.id,
                    remoteSnapshotID: remoteHead.snapshotID,
                    remoteGeneration: remoteHead.generation
                )
                latestOutcome = .uploaded(snapshotID: snapshot.id, generation: remoteHead.generation)
            } catch SnapshotSyncError.conflict {
                return .needsChoice(snapshotID: snapshot.id)
            }
        }
        return latestOutcome
    }

    public func conflicts(workID: UUID) async throws -> [SnapshotSyncConflict] {
        let maybeSession: FuminiwaSession?
        do {
            maybeSession = try await sessionProvider()
        } catch {
            throw SnapshotSyncError.offline
        }
        guard let session = maybeSession else { throw SnapshotSyncError.offline }
        return try await transport.conflicts(workID: workID, accessToken: session.accessToken)
    }

    public func library() async throws -> [SnapshotSyncLibraryEntry] {
        guard let session = try await sessionProvider() else { throw SnapshotSyncError.offline }
        return try await transport.library(accessToken: session.accessToken)
    }

    public func remoteHead(workID: UUID) async throws -> RemoteSnapshotHead? {
        guard let session = try await sessionProvider() else { throw SnapshotSyncError.offline }
        return try await transport.head(workID: workID, accessToken: session.accessToken)
    }

    public func remoteSnapshot(
        workID: UUID,
        snapshotID: String
    ) async throws -> RemoteSnapshotPayload {
        guard let session = try await sessionProvider() else {
            throw SnapshotSyncError.offline
        }
        let manifest = try await transport.snapshotManifest(
            workID: workID,
            snapshotID: snapshotID,
            accessToken: session.accessToken
        )
        let objectIDs = try Self.objectIDs(in: manifest)
        var objects: [LocalObject] = []
        objects.reserveCapacity(objectIDs.count)
        for objectID in objectIDs {
            let bytes = try await transport.downloadObject(
                objectID: objectID,
                accessToken: session.accessToken
            )
            objects.append(LocalObject(objectID: objectID, bytes: bytes))
        }
        let parentIDs = try Self.parentIDs(in: manifest)
        return RemoteSnapshotPayload(
            workID: workID,
            snapshotID: snapshotID,
            parentSnapshotIDs: parentIDs,
            manifest: manifest,
            objects: objects
        )
    }

    /// Publishes the already durable local branch against the server head
    /// observed by the conflict record. A newer local edit remains pending
    /// because `acknowledge` is generation-aware.
    public func resolveUsingLocal(_ conflict: SnapshotSyncConflict) async throws -> SnapshotSyncOutcome {
        guard let session = try await sessionProvider() else { throw SnapshotSyncError.offline }
        guard let snapshot = try await store.snapshot(id: conflict.localSnapshotID) else {
            throw SnapshotSyncError.transport("missing local conflict snapshot")
        }
        // A conflict can be selected before the original outbox attempt has
        // completed. Re-send the complete immutable chain first; publishing
        // an unregistered leaf would otherwise fail even though the local
        // snapshot itself is valid.
        _ = try await ensureSnapshotChain(
            snapshot,
            workID: conflict.workID,
            accessToken: session.accessToken,
            visited: []
        )
        let expectedHead = try await transport.head(workID: conflict.workID, accessToken: session.accessToken)
        let head = try await transport.publish(
            workID: conflict.workID,
            // The conflict ID is the durable operation identity for this
            // explicit choice. A lost response can therefore be replayed
            // without advancing the head twice.
            operationID: conflict.conflictID,
            expectedHead: expectedHead,
            candidateSnapshotID: snapshot.id,
            accessToken: session.accessToken
        )
        for intent in try await store.pendingIntents(for: conflict.workID)
            where intent.localSnapshotID == conflict.localSnapshotID {
            _ = try await store.acknowledge(
                intentID: intent.id,
                remoteSnapshotID: head.snapshotID,
                remoteGeneration: head.generation
            )
        }
        return .uploaded(snapshotID: snapshot.id, generation: head.generation)
    }

    public func resolveUsingServer(
        _ conflict: SnapshotSyncConflict,
        keepBoth: Bool = false
    ) async throws {
        guard let session = try await sessionProvider() else { throw SnapshotSyncError.offline }
        let head = try await transport.head(workID: conflict.workID, accessToken: session.accessToken)
        guard let head else {
            throw SnapshotSyncError.transport("missing remote head for conflict resolution")
        }

        // The server resolves every needsChoice record for this work that
        // points at the validated current head in one atomic operation. Keep
        // one durable request ID (the selected conflict ID) so a lost
        // response can be replayed without creating a second resolution.
        do {
            try await transport.resolveConflict(
                workID: conflict.workID,
                conflictID: conflict.conflictID,
                choice: keepBoth ? .keepBoth : .useServer,
                expectedRemoteSnapshotID: head.snapshotID,
                accessToken: session.accessToken
            )
        } catch let SnapshotSyncError.transport(message)
            where message.contains("conflict already resolved") {
            // Another retry may have completed this exact record between
            // reading the head and sending the resolution. It is safe to
            // treat that response as success because the operation is
            // idempotent on the server.
        }
    }

    private func ensureSnapshotChain(
        _ snapshot: LocalSnapshotRecord,
        workID: UUID,
        accessToken: String,
        visited: Set<String>
    ) async throws -> Set<String> {
        var visited = visited
        guard visited.insert(snapshot.id).inserted else { return visited }
        for parentID in snapshot.parentSnapshotIDs {
            guard let parent = try await store.snapshot(id: parentID) else {
                throw SnapshotSyncError.transport("missing local parent snapshot \(parentID)")
            }
            visited = try await ensureSnapshotChain(
                parent,
                workID: workID,
                accessToken: accessToken,
                visited: visited
            )
        }
        let objectIDs = try Self.objectIDs(in: snapshot.manifest)
        for objectID in objectIDs {
            guard let bytes = try await store.object(id: objectID) else {
                throw SnapshotSyncError.transport("missing local object \(objectID)")
            }
            try await transport.uploadObject(
                objectID: objectID,
                bytes: bytes,
                accessToken: accessToken
            )
        }
        try await transport.registerSnapshot(
            workID: workID,
            snapshotID: snapshot.id,
            manifest: snapshot.manifest,
            accessToken: accessToken
        )
        return visited
    }

    private static func objectIDs(in manifest: Data) throws -> [String] {
        guard let object = try JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              let entries = object["entries"] as? [[String: Any]] else {
            // An empty object set is valid for migration/metadata snapshots;
            // the server will still validate the manifest shape.
            return []
        }
        let ids = entries.compactMap { $0["objectId"] as? String }
        guard ids.count == entries.count else { throw SnapshotSyncError.invalidManifest }
        return Array(Set(ids)).sorted()
    }

    private static func parentIDs(in manifest: Data) throws -> [String] {
        guard let object = try JSONSerialization.jsonObject(with: manifest) as? [String: Any] else {
            throw SnapshotSyncError.invalidManifest
        }
        return object["parentSnapshotIds"] as? [String] ?? []
    }
}

public struct FuminiwaHTTPSnapshotSyncTransport: SnapshotSyncTransport, Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func library(accessToken: String) async throws -> [SnapshotSyncLibraryEntry] {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/works"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try validate(response, status: 200 ..< 300, data: data)
        return try JSONDecoder().decode([SnapshotSyncLibraryEntry].self, from: data)
    }

    public func snapshotManifest(
        workID: UUID,
        snapshotID: String,
        accessToken: String
    ) async throws -> Data {
        var request = URLRequest(
            url: baseURL.appendingPathComponent(
                "v1/works/\(workID.uuidString.lowercased())/snapshots/\(snapshotID)"
            )
        )
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try validate(response, status: 200 ..< 300, data: data)
        return data
    }

    public func downloadObject(objectID: String, accessToken: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/objects/\(objectID)"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try validate(response, status: 200 ..< 300, data: data)
        return data
    }

    public func uploadObject(objectID: String, bytes: Data, accessToken: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/objects/\(objectID)"))
        request.httpMethod = "PUT"
        request.httpBody = bytes
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        try await send(request, expected: 200 ..< 300)
    }

    public func registerSnapshot(workID: UUID, snapshotID: String, manifest: Data, accessToken: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/works/\(workID.uuidString.lowercased())/snapshots/\(snapshotID)"))
        request.httpMethod = "PUT"
        request.httpBody = manifest
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try await send(request, expected: 200 ..< 300)
    }

    public func head(workID: UUID, accessToken: String) async throws -> RemoteSnapshotHead? {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/works/\(workID.uuidString.lowercased())/head"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try validate(response, status: 200 ..< 300, data: data)
        return try JSONDecoder().decode(RemoteSnapshotHead?.self, from: data)
    }

    public func publish(
        workID: UUID,
        operationID: UUID,
        expectedHead: RemoteSnapshotHead?,
        candidateSnapshotID: String,
        accessToken: String
    ) async throws -> RemoteSnapshotHead {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/works/\(workID.uuidString.lowercased())/head"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = PublishBody(
            operationID: operationID,
            workID: workID,
            expectedHead: expectedHead,
            candidateSnapshotID: candidateSnapshotID
        )
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 409 {
            throw SnapshotSyncError.conflict
        }
        try validate(response, status: 200 ..< 300, data: data)
        return try JSONDecoder().decode(PublishResponse.self, from: data).head
    }

    public func conflicts(workID: UUID, accessToken: String) async throws -> [SnapshotSyncConflict] {
        var request = URLRequest(
            url: baseURL.appendingPathComponent(
                "v1/works/\(workID.uuidString.lowercased())/conflicts"
            )
        )
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try validate(response, status: 200 ..< 300, data: data)
        return try JSONDecoder().decode([SnapshotSyncConflict].self, from: data)
    }

    public func resolveConflict(
        workID: UUID,
        conflictID: UUID,
        choice: SnapshotSyncConflictChoice,
        expectedRemoteSnapshotID: String,
        accessToken: String
    ) async throws {
        var request = URLRequest(
            url: baseURL.appendingPathComponent(
                "v1/works/\(workID.uuidString.lowercased())/conflicts/\(conflictID.uuidString.lowercased())/resolve"
            )
        )
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(
            ResolveConflictBody(
                // Conflict IDs are durable server-side handles. Reusing this
                // ID makes a retry after a lost response replay the exact
                // resolution instead of creating a new operation each time.
                operationID: conflictID,
                choice: choice.rawValue,
                expectedRemoteSnapshotID: expectedRemoteSnapshotID
            )
        )
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        try validate(response, status: 200 ..< 300, data: data)
    }

    private func send(_ request: URLRequest, expected: Range<Int>) async throws {
        let (data, response) = try await session.data(for: request)
        try validate(response, status: expected, data: data)
    }

    private func validate(_ response: URLResponse, status: Range<Int>, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw SnapshotSyncError.transport("not an HTTP response")
        }
        if http.statusCode == 401 {
            throw SnapshotSyncError.unauthorized
        }
        guard status.contains(http.statusCode) else {
            throw SnapshotSyncError.transport("HTTP \(http.statusCode): \(String(decoding: data, as: UTF8.self))")
        }
    }
}

private struct PublishBody: Encodable {
    let operationID: UUID
    let workID: UUID
    let expectedHead: RemoteSnapshotHead?
    let candidateSnapshotID: String

    enum CodingKeys: String, CodingKey {
        case operationID = "operationId"
        case workID = "workId"
        case expectedHead
        case candidateSnapshotID = "candidateSnapshotId"
    }
}

private struct PublishResponse: Decodable {
    let head: RemoteSnapshotHead
}

private struct ResolveConflictBody: Encodable {
    let operationID: UUID
    let choice: String
    let expectedRemoteSnapshotID: String

    enum CodingKeys: String, CodingKey {
        case operationID = "operationId"
        case choice
        case expectedRemoteSnapshotID = "expectedRemoteSnapshotId"
    }
}
