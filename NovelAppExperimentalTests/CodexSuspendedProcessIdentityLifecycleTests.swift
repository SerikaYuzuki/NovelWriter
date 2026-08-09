import Darwin
import Foundation
@testable import FUMINIWAExperimental
import Testing

@Suite("Codex suspended-process lifecycle", .serialized)
struct CodexSuspendedLifecycleTests {
    @Test("consumer cancellationは停止childをkill/reapしてからcancelledを返す")
    func consumerCancellationKillsAndReaps() async throws {
        let fixture = try systemSuspendedProcessFixture()
        let request = try suspendedProcessRequest(fixture: fixture)
        let inspector = CodexSuspendedProcessIdentityInspector()
        let processID = SuspendedProcessPIDCapture()
        let gate = SuspendedProcessHookGate()
        let watchdog = suspendedProcessCleanupWatchdog(
            executablePath: fixture.absolutePath
        )
        defer {
            gate.open()
            watchdog.cancel()
        }
        let task = Task {
            try await inspector.inspect(
                request,
                testingHooks: CodexSuspendedProcessIdentityInspectorTestingHooks(
                    afterSuspendedSpawn: {
                        processID.recordStoppedDirectChild(
                            executablePath: fixture.absolutePath
                        )
                        gate.enterAndWait()
                    }
                )
            )
        }

        #expect(await gate.waitUntilEntered())
        task.cancel()
        gate.open()
        let error = await capturedSuspendedProcessError {
            _ = try await task.value
        }

        #expect(error == .cancelled)
        try await expectSuspendedProcessWasKilledAndReaped(processID.value())
    }

    @Test("explicit duplicate cancelも一つのcancelled terminalとdirect reapになる")
    func explicitDuplicateCancellationIsIdempotent() async throws {
        let fixture = try systemSuspendedProcessFixture()
        let request = try suspendedProcessRequest(fixture: fixture)
        let inspector = CodexSuspendedProcessIdentityInspector()
        let processID = SuspendedProcessPIDCapture()
        let gate = SuspendedProcessHookGate()
        let watchdog = suspendedProcessCleanupWatchdog(
            executablePath: fixture.absolutePath
        )
        defer {
            gate.open()
            watchdog.cancel()
        }
        let task = Task {
            try await inspector.inspect(
                request,
                testingHooks: CodexSuspendedProcessIdentityInspectorTestingHooks(
                    afterSuspendedSpawn: {
                        processID.recordStoppedDirectChild(
                            executablePath: fixture.absolutePath
                        )
                        gate.enterAndWait()
                    }
                )
            )
        }

        #expect(await gate.waitUntilEntered())
        async let firstCancel: Void = inspector.cancel()
        async let secondCancel: Void = inspector.cancel()
        _ = await (firstCancel, secondCancel)
        gate.open()
        let error = await capturedSuspendedProcessError {
            _ = try await task.value
        }

        #expect(error == .cancelled)
        try await expectSuspendedProcessWasKilledAndReaped(processID.value())
    }

    @Test("inspection phaseがdeadlineを越えても停止childをreapしてtimedOutを返す")
    func phaseTimeoutKillsAndReaps() async throws {
        let fixture = try systemSuspendedProcessFixture()
        let request = try suspendedProcessRequest(
            fixture: fixture,
            timeout: .milliseconds(20)
        )
        let processID = SuspendedProcessPIDCapture()
        let watchdog = suspendedProcessCleanupWatchdog(
            executablePath: fixture.absolutePath
        )
        defer { watchdog.cancel() }

        let error = await capturedSuspendedProcessError {
            _ = try await CodexSuspendedProcessIdentityInspector().inspect(
                request,
                testingHooks: CodexSuspendedProcessIdentityInspectorTestingHooks(
                    afterSuspendedSpawn: {
                        processID.recordStoppedDirectChild(
                            executablePath: fixture.absolutePath
                        )
                    },
                    beforeActualIdentityInspection: {
                        usleep(80000)
                    }
                )
            )
        }

        #expect(error == .timedOut)
        try await expectSuspendedProcessWasKilledAndReaped(processID.value())
    }

    @Test("spawn直前のconsumer cancellationはchildを生成せずcancelledを返す")
    func cancellationBeforeSpawnCreatesNoChild() async throws {
        let fixture = try systemSuspendedProcessFixture()
        let request = try suspendedProcessRequest(fixture: fixture)
        let inspector = CodexSuspendedProcessIdentityInspector()
        let gate = SuspendedProcessHookGate()
        let afterSpawn = SuspendedProcessHookCounter()
        let watchdog = suspendedProcessCleanupWatchdog(
            executablePath: fixture.absolutePath
        )
        defer {
            gate.open()
            watchdog.cancel()
        }
        let task = Task {
            try await inspector.inspect(
                request,
                testingHooks: CodexSuspendedProcessIdentityInspectorTestingHooks(
                    beforeSuspendedSpawn: {
                        gate.enterAndWait()
                    },
                    afterSuspendedSpawn: {
                        afterSpawn.increment()
                    }
                )
            )
        }

        #expect(await gate.waitUntilEntered())
        task.cancel()
        gate.open()
        let error = await capturedSuspendedProcessError {
            _ = try await task.value
        }

        #expect(error == .cancelled)
        #expect(afterSpawn.value() == 0)
    }

    @Test("spawn直前のdeadline超過はchildを生成せずtimedOutを返す")
    func timeoutBeforeSpawnCreatesNoChild() async throws {
        let fixture = try systemSuspendedProcessFixture()
        let request = try suspendedProcessRequest(
            fixture: fixture,
            timeout: .milliseconds(20)
        )
        let afterSpawn = SuspendedProcessHookCounter()
        let watchdog = suspendedProcessCleanupWatchdog(
            executablePath: fixture.absolutePath
        )
        defer { watchdog.cancel() }

        let error = await capturedSuspendedProcessError {
            _ = try await CodexSuspendedProcessIdentityInspector().inspect(
                request,
                testingHooks: CodexSuspendedProcessIdentityInspectorTestingHooks(
                    beforeSuspendedSpawn: {
                        usleep(80000)
                    },
                    afterSuspendedSpawn: {
                        afterSpawn.increment()
                    }
                )
            )
        }

        #expect(error == .timedOut)
        #expect(afterSpawn.value() == 0)
    }

    @Test("同じinspectorの並行2件目はspawnせずalreadyRunningで拒否する")
    func rejectsConcurrentSecondProbe() async throws {
        let fixture = try systemSuspendedProcessFixture()
        let request = try suspendedProcessRequest(fixture: fixture)
        let inspector = CodexSuspendedProcessIdentityInspector()
        let processID = SuspendedProcessPIDCapture()
        let gate = SuspendedProcessHookGate()
        let firstTask = Task {
            try await inspector.inspect(
                request,
                testingHooks: CodexSuspendedProcessIdentityInspectorTestingHooks(
                    afterSuspendedSpawn: {
                        processID.recordStoppedDirectChild(
                            executablePath: fixture.absolutePath
                        )
                        gate.enterAndWait()
                    }
                )
            )
        }
        let watchdog = suspendedProcessCleanupWatchdog(
            executablePath: fixture.absolutePath
        )
        defer {
            gate.open()
            watchdog.cancel()
        }
        #expect(await gate.waitUntilEntered())

        let secondError = await capturedSuspendedProcessError {
            _ = try await inspector.inspect(request)
        }
        #expect(secondError == .alreadyRunning)

        await inspector.cancel()
        gate.open()
        let firstError = await capturedSuspendedProcessError {
            _ = try await firstTask.value
        }
        #expect(firstError == .cancelled)
        try await expectSuspendedProcessWasKilledAndReaped(processID.value())
    }
}
