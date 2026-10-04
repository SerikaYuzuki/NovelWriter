import Foundation
import NovelSyncV2
import NovelSyncV2Application
import NovelWorkspace
import Testing

@MainActor
struct LibraryCoordinatorImportTests {
    @Test("監視はopeningを保持し、取り込み状態とfailureを置換する")
    func monitoringKeepsOpening() async {
        let host = FakeLibraryHost(), backend = FakeLibraryOperations()
        let opening = WorkID(UUID()), importing = WorkID(UUID())
        host.libraryOpeningWorkID = opening
        host.libraryImportPhases[opening] = .init(stage: .opening)
        backend.phases[importing] = .init(stage: .opening)
        backend.failures[importing] = .offline
        #expect(await LibraryCoordinator(operations: backend.operations).updateImports(account: host.account, host: host))
        #expect(host.libraryImportPhases[opening]?.stage == .opening)
        #expect(host.libraryImportPhases[importing]?.stage == .opening)
        #expect(host.libraryImportFailures[importing] == .offline)
        host.libraryOpeningWorkID = nil
        #expect(await LibraryCoordinator(operations: backend.operations).updateImports(account: host.account, host: host))
        #expect(host.libraryImportPhases[opening] == nil)
    }

    @Test("監視のawait中にaccountが変わったら状態を反映しない")
    func staleMonitoring() async {
        let host = FakeLibraryHost(), backend = FakeLibraryOperations()
        let account = host.account
        backend.onImports = { host.invalidateAccount() }
        backend.failures[WorkID(UUID())] = .offline
        #expect(await !LibraryCoordinator(operations: backend.operations).updateImports(account: account, host: host))
        #expect(host.libraryImportFailures.isEmpty)
    }

    @Test("端末への取り込みは現在の本文・sessionを保持し、再入と古い完了を拒否する", arguments: [0, 1, 2, 3])
    func takeDoesNotInstall(result: Int) async throws {
        let host = FakeLibraryHost(), backend = FakeLibraryOperations()
        let controller = SyncSessionController<Bool>()
        let document = host.document, session = host.session
        let target = WorkID(UUID())
        var calls = 0
        backend.onPrefetch = {
            calls += 1
            if result == 1 {
                host.invalidateAccount()
            }
            if result == 2 {
                throw SyncV2Failure.offline
            }
        }
        host.onRefresh = {
            if result == 3 {
                host.invalidateAccount()
            }
        }
        let coordinator = LibraryCoordinator(operations: backend.operations)
        coordinator.takeOntoDevice(workID: target, title: "取得", controller: controller, host: host)
        let task = try #require(controller.prefetchTask)
        coordinator.takeOntoDevice(workID: target, title: "再入", controller: controller, host: host)
        await task.value
        #expect(calls == 1)
        #expect(host.document == document)
        #expect(host.session == session)
        #expect(controller.prefetchTask == nil)
        #expect(host.announcements.count == (result == 0 || result == 2 ? 1 : 0))
        #expect(host.libraryImportFailures[target] == (result == 2 ? .offline : nil))
    }

    @Test("取消はapplicationと両taskを止め、終了を待って棚を更新する")
    func cancelWaitsForBothTasks() async {
        let host = FakeLibraryHost(), backend = FakeLibraryOperations()
        let controller = SyncSessionController<Bool>()
        let target = WorkID(UUID())
        controller.prefetchWorkID = target
        controller.remoteOnlyWorkID = WorkID(UUID())
        controller.prefetchTask = Task {
            do { try await Task.sleep(for: .seconds(60)) } catch {}
            #expect(Task.isCancelled)
            host.events.append("prefetch-finished")
        }
        controller.remoteOnlyTask = Task {
            do { try await Task.sleep(for: .seconds(60)) } catch {}
            #expect(Task.isCancelled)
            host.events.append("open-finished")
            return false
        }
        await LibraryCoordinator.cancelImports(operations: backend.operations, controller: controller, host: host)
        #expect(backend.events == ["cancel:\(target)"])
        #expect(host.events.last == "refresh")
        #expect(Set(host.events.dropLast()) == ["prefetch-finished", "open-finished"])
    }
}
