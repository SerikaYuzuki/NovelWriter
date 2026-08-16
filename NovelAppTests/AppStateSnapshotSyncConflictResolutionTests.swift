import Foundation
@testable import FUMINIWA
import NovelAuth
import NovelCore
import NovelLocalStore
import NovelSync
import Testing

@MainActor
@Suite("macOS snapshot conflict resolution")
struct AppStateSnapshotSyncConflictResolutionTests {
    @Test("useServer installs the remote document and clears duplicate conflicts")
    func useServerFollowsTheAppStateActionPath() async throws {
        let work = NovelDocument.newDocument(title: "端末の版")
        var remote = work
        remote.title = "サーバーの版"
        remote.updateSelectedEpisodeContentForTest("サーバー本文")

        let defaults = try #require(
            UserDefaults(suiteName: "FUMINIWAConflictResolution.\(UUID().uuidString)")
        )
        let session = FuminiwaSession(
            accessToken: "test-access-token",
            refreshToken: "test-refresh-token",
            accountID: "test-account",
            accountAuthEpoch: 1,
            accountFence: "test-fence",
            refreshGeneration: 1
        )
        let vault = InMemoryAuthSessionVault(session: session)
        let auth = AuthSessionCoordinator(transport: NoopAuthTransport(), vault: vault)
        let remoteSnapshot = try makeSnapshotPayload(remote)
        let transport = FakeSnapshotSyncTransport(
            head: RemoteSnapshotHead(generation: 7, snapshotID: remoteSnapshot.snapshotID),
            payload: remoteSnapshot.payload
        )
        let state = AppState(
            dependencies: AppDependencies(
                repository: NoopDocumentRepository(),
                userDefaults: defaults,
                defaultDocumentDirectoryName: "Conflict-\(UUID().uuidString)",
                authSessionCoordinator: auth,
                snapshotSyncTransport: transport
            ),
            initialStartupState: .ready
        )
        let store = try #require(state.localCanonicalStore)
        let localSnapshot = try makeSnapshotPayload(work)
        _ = try await store.commitSnapshot(
            workID: work.id,
            documentID: work.id,
            documentCreatedAt: "2026-08-17T00:00:00Z",
            snapshotID: localSnapshot.snapshotID,
            parentSnapshotIDs: [],
            manifest: localSnapshot.payload.manifest,
            objects: localSnapshot.payload.objects,
            reason: .autosave
        )
        let intents = try await store.pendingIntents(for: work.id)
        #expect(intents.count == 1)
        let intent = try #require(intents.first)
        _ = try await store.acknowledge(
            intentID: intent.id,
            remoteSnapshotID: String(repeating: "b", count: 64),
            remoteGeneration: 1
        )

        let packageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWA-Conflict-\(UUID().uuidString).novelpkg", isDirectory: true)
        state.installDocument(work, at: packageURL, attachments: [])
        let conflictID = try #require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000101")
        )
        let conflict = try JSONDecoder().decode(
            SnapshotSyncConflict.self,
            from: Data("""
            {
              "conflict_id": "\(conflictID.uuidString)",
              "work_id": "\(work.id.uuidString)",
              "base_snapshot_id": null,
              "local_snapshot_id": "\(localSnapshot.snapshotID)",
              "remote_snapshot_id": "\(remoteSnapshot.snapshotID)",
              "state": "needsChoice",
              "created_at": "2026-08-17T00:00:00Z"
            }
            """.utf8)
        )
        await transport.setConflicts([conflict, conflict])
        state.snapshotSyncConflict = conflict

        #expect(state.usesSnapshotSyncRuntime)
        #expect(await state.resolveSnapshotConflict(using: .useServer))
        #expect(state.document.title == remote.title)
        #expect(state.selectedEpisode?.content == "サーバー本文")
        #expect(state.snapshotSyncConflict == nil)

        let calls = await transport.resolveCalls()
        #expect(calls.count == 1)
        #expect(calls.first?.workID == work.id)
        #expect(calls.first?.conflictID == conflict.conflictID)
        #expect(calls.first?.choice == .useServer)
        #expect(calls.first?.expectedRemoteSnapshotID == remoteSnapshot.snapshotID)
        let finalState = try await store.workState(for: work.id)
        #expect(finalState?.acknowledgedHeadSnapshotID == remoteSnapshot.snapshotID)
    }

    private func makeSnapshotPayload(_ document: NovelDocument) throws -> SnapshotFixture {
        let snapshot = try WorkSnapshot(document: document)
        let objectBytes = try WorkCanonicalJSON.encodeSnapshot(snapshot)
        let objectID = SyncContentDigest(content: String(decoding: objectBytes, as: UTF8.self)).rawValue
        struct Entry: Encodable {
            let byteCount: Int
            let contentType: String
            let entityKey: String
            let objectId: String
        }
        struct Manifest: Encodable {
            let entries: [Entry]
            let parentSnapshotIds: [String]
            let schemaVersion: Int
            let workId: UUID
        }
        let manifest = Manifest(
            entries: [Entry(
                byteCount: objectBytes.count,
                contentType: "application/json",
                entityKey: "work/document",
                objectId: objectID
            )],
            parentSnapshotIds: [],
            schemaVersion: 1,
            workId: document.id
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let manifestBytes = try encoder.encode(manifest)
        let snapshotID = SyncContentDigest(content: String(decoding: manifestBytes, as: UTF8.self)).rawValue
        return SnapshotFixture(
            snapshotID: snapshotID,
            payload: RemoteSnapshotPayload(
                workID: document.id,
                snapshotID: snapshotID,
                parentSnapshotIDs: [],
                manifest: manifestBytes,
                objects: [LocalObject(objectID: objectID, bytes: objectBytes)]
            )
        )
    }
}

private struct SnapshotFixture {
    let snapshotID: String
    let payload: RemoteSnapshotPayload
}

private struct NoopDocumentRepository: DocumentRepository {
    func load(from _: URL) async throws -> NovelDocument {
        .newDocument()
    }

    func save(_: NovelDocument, to _: URL) async throws {}
}

private struct NoopAuthTransport: FuminiwaAuthTransport {
    func createAppleChallenge() async throws -> AuthChallenge {
        throw AuthError.providerRejected
    }

    func exchangeApple(
        challenge _: AuthChallenge,
        authorizationCode _: Data,
        identityToken _: Data,
        operationID _: UUID
    ) async throws -> FuminiwaSession {
        throw AuthError.providerRejected
    }

    func refresh(session _: FuminiwaSession, rotationID _: UUID) async throws -> FuminiwaSession {
        throw AuthError.providerRejected
    }

    func revoke(session _: FuminiwaSession) async throws {}
}

private actor FakeSnapshotSyncTransport: SnapshotSyncTransport {
    struct ResolveCall: Sendable {
        let workID: UUID
        let conflictID: UUID
        let choice: SnapshotSyncConflictChoice
        let expectedRemoteSnapshotID: String
    }

    private let remoteHead: RemoteSnapshotHead
    private let payload: RemoteSnapshotPayload
    private var pendingConflicts: [SnapshotSyncConflict] = []
    private var calls: [ResolveCall] = []

    init(head: RemoteSnapshotHead, payload: RemoteSnapshotPayload) {
        remoteHead = head
        self.payload = payload
    }

    func setConflicts(_ conflicts: [SnapshotSyncConflict]) {
        pendingConflicts = conflicts
    }

    func resolveCalls() -> [ResolveCall] {
        calls
    }

    func library(accessToken _: String) async throws -> [SnapshotSyncLibraryEntry] {
        []
    }

    func snapshotManifest(workID _: UUID, snapshotID _: String, accessToken _: String) async throws -> Data {
        payload.manifest
    }

    func downloadObject(objectID: String, accessToken _: String) async throws -> Data {
        guard let object = payload.objects.first(where: { $0.objectID == objectID }) else {
            throw SnapshotSyncError.transport("missing object")
        }
        return object.bytes
    }

    func uploadObject(objectID _: String, bytes _: Data, accessToken _: String) async throws {}

    func registerSnapshot(workID _: UUID, snapshotID _: String, manifest _: Data, accessToken _: String) async throws {}

    func head(workID _: UUID, accessToken _: String) async throws -> RemoteSnapshotHead? {
        remoteHead
    }

    func publish(
        workID _: UUID,
        operationID _: UUID,
        expectedHead _: RemoteSnapshotHead?,
        candidateSnapshotID _: String,
        accessToken _: String
    ) async throws -> RemoteSnapshotHead {
        throw SnapshotSyncError.conflict
    }

    func conflicts(workID _: UUID, accessToken _: String) async throws -> [SnapshotSyncConflict] {
        pendingConflicts
    }

    func resolveConflict(
        workID: UUID,
        conflictID: UUID,
        choice: SnapshotSyncConflictChoice,
        expectedRemoteSnapshotID: String,
        accessToken _: String
    ) async throws {
        calls.append(ResolveCall(
            workID: workID,
            conflictID: conflictID,
            choice: choice,
            expectedRemoteSnapshotID: expectedRemoteSnapshotID
        ))
        pendingConflicts = []
    }
}

private extension NovelDocument {
    mutating func updateSelectedEpisodeContentForTest(_ content: String) {
        guard let chapter = chapters.first, let episode = chapter.episodes.first else { return }
        updateEpisodeContent(content, for: episode.id, in: chapter.id)
    }
}
