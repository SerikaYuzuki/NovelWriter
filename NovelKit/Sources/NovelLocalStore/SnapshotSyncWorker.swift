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

public enum SnapshotSyncOutcome: Equatable, Sendable {
    case offline
    case idle
    case uploaded(snapshotID: String, generation: UInt64)
    case needsChoice(snapshotID: String)
}

public enum SnapshotSyncError: Error, Equatable, Sendable {
    case invalidManifest
    case transport(String)
    case unauthorized
    case conflict
}

public protocol SnapshotSyncTransport: Sendable {
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
            let objectIDs = try Self.objectIDs(in: snapshot.manifest)
            for objectID in objectIDs {
                guard let bytes = try await store.object(id: objectID) else {
                    throw SnapshotSyncError.transport("missing local object \(objectID)")
                }
                try await transport.uploadObject(
                    objectID: objectID,
                    bytes: bytes,
                    accessToken: session.accessToken
                )
            }
            try await transport.registerSnapshot(
                workID: workID,
                snapshotID: snapshot.id,
                manifest: snapshot.manifest,
                accessToken: session.accessToken
            )
            let state = try await store.workState(for: workID)
            let expectedHead = state?.acknowledgedHeadSnapshotID.map {
                RemoteSnapshotHead(
                    generation: state?.acknowledgedHeadGeneration ?? 0,
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
}

public struct FuminiwaHTTPSnapshotSyncTransport: SnapshotSyncTransport, Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
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
