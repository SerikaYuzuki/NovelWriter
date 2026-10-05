import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelWorkspace
import Testing

@MainActor
struct WorkOpenCoordinatorTests {
    private func opened(_ workID: WorkID, document: NovelDocument = .newDocument(title: "取得版")) -> SyncV2OpenedWork {
        .init(workID: workID, document: document, documentCreatedAt: Date(), generation: 1, snapshotID: nil)
    }

    private func coordinator(_ value: SyncV2OpenedWork) -> WorkOpenCoordinator {
        .init(openLocal: { _ in value }, download: { _ in value }, isCurrentLocalVersion: { _ in true },
              beginSession: { .init(workID: $0, identity: UUID(), revision: 1) })
    }

    @Test("shared local/remote open rejects a response for another WorkID", arguments: [false, true])
    func mismatchedWorkID(remote: Bool) async throws {
        let service = coordinator(opened(WorkID(UUID())))
        let requested = WorkID(UUID())
        await #expect(throws: SyncV2ApplicationError.safeBoundaryRejected) {
            if remote {
                _ = try await service.downloadRemoteOnly(workID: requested, isCurrent: { true }, opening: {
                    Issue.record("invalid response must not enter opening stage")
                })
            } else {
                _ = try await service.readLocal(workID: requested, isCurrent: { true })
            }
        }
    }

    @Test("download permits editing outside the gate; prepared install checks SQLite before session/install")
    func downloadThenPreparedInstall() async throws {
        let host = FakeLibraryHost(), requested = WorkID(UUID())
        let value = opened(requested)
        let expected = CheckpointCoordinator.context(of: host)
        var service = coordinator(value)
        service.download = { _ in
            #expect(!host.gateHeld)
            host.events.append("download")
            host.generation += 1
            return value
        }
        service.isCurrentLocalVersion = { _ in
            #expect(host.gateHeld)
            #expect(host.events == ["download", "opening", "IME/save"])
            host.events.append("CAS")
            return true
        }
        service.beginSession = { id in
            host.events.append("session")
            return .init(workID: id, identity: UUID(), revision: 1)
        }
        let downloaded = try #require(await service.downloadRemoteOnly(
            workID: requested, isCurrent: { CheckpointCoordinator.matches(expected, host: host) },
            opening: { host.events.append("opening") }
        ))
        host.gateHeld = true
        host.events.append("IME/save")
        let installed = try await service.installAtPreparedBoundary(
            downloaded, workID: requested, host: host, verifiesLocalVersion: true, createsSession: true,
            install: { value, session in
                #expect(session?.workID == requested)
                host.events.append("install")
                host.document = value.document!
                host.workID = requested
                host.session = .init(generation: 2, documentID: host.document.id, workID: requested)
                return true
            }, project: { _ in host.events.append("project") }
        )
        #expect(installed)
        #expect(host.events == ["download", "opening", "IME/save", "CAS", "session", "install", "project"])
    }

    @Test("suspended open/install never replaces another work or a newer boundary",
          arguments: ["read", "CAS", "session"], ["work", "session", "account", "edit"])
    func staleBoundary(step: String, change: String) async throws {
        let host = FakeLibraryHost(), requested = WorkID(UUID())
        let original = host.document, expected = host.operationContext
        let value = opened(requested)
        let invalidate = {
            switch change {
            case "work": host.workID = WorkID(UUID())
            case "session": host.session?.generation += 1
            case "account": host.invalidateAccount()
            default: host.generation += 1
            }
        }
        var service = coordinator(value)
        service.openLocal = { _ in
            await Task.yield()
            if step == "read" {
                invalidate()
            }
            return value
        }
        service.isCurrentLocalVersion = { _ in
            await Task.yield()
            if step == "CAS" {
                invalidate()
            }
            return true
        }
        service.beginSession = { id in
            await Task.yield()
            if step == "session" {
                invalidate()
            }
            return .init(workID: id, identity: UUID(), revision: 1)
        }
        if step == "read" {
            #expect(try await service.readLocal(workID: requested, isCurrent: { expected.isCurrent(host.operationContext) }) == nil)
        } else {
            #expect(try await service.installAtPreparedBoundary(
                value, workID: requested, host: host, verifiesLocalVersion: true, createsSession: true,
                install: { _, _ in Issue.record("stale install"); return true }
            ) == false)
        }
        #expect(host.document == original)
    }

    @Test("load failure and a stale local version preserve the manuscript", arguments: [false, true])
    func loadFailure(versionChanged: Bool) async throws {
        let host = FakeLibraryHost(), original = host.document, value = opened(WorkID(UUID()))
        var service = coordinator(value)
        service.openLocal = { _ in throw SyncV2Failure.offline }
        service.isCurrentLocalVersion = { _ in false }
        if versionChanged {
            #expect(try await service.installAtPreparedBoundary(
                value, workID: value.workID, host: host, verifiesLocalVersion: true,
                install: { _, _ in Issue.record("stale version install"); return true }
            ) == false)
        } else {
            await #expect(throws: SyncV2Failure.offline) {
                _ = try await service.readLocal(workID: value.workID, isCurrent: { true })
            }
        }
        #expect(host.document == original)
    }
}
