import Darwin
import Foundation
@testable import FUMINIWAExperimental
import Testing

@Test("group/world writable executableはspawn前に拒否する")
func codexSupervisorRejectsMutableExecutable() throws {
    let temporaryDirectory = try makeSupervisorTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let executableURL = temporaryDirectory.appending(path: "mutable-helper")
    try FileManager.default.copyItem(
        at: URL(fileURLWithPath: "/usr/bin/true"),
        to: executableURL
    )
    #expect(chmod(executableURL.path, 0o777) == 0)

    do {
        _ = try supervisorInvocation(
            executablePath: executableURL.path,
            workingDirectory: temporaryDirectory
        )
        Issue.record("expected invalidExecutablePath")
    } catch let error as CodexProcessSupervisorError {
        #expect(error == .invalidExecutablePath)
    }
}

@Test("CLOEXEC_DEFAULTはparentの高位sentinel FDをchildへ継承しない")
func codexSupervisorDoesNotInheritUnlistedFileDescriptor() async throws {
    let temporaryDirectory = try makeSupervisorTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let sourceDescriptor = open("/dev/null", O_WRONLY)
    #expect(sourceDescriptor >= 0)
    let sentinelDescriptor = fcntl(sourceDescriptor, F_DUPFD, 200)
    _ = close(sourceDescriptor)
    guard sentinelDescriptor >= 0 else {
        Issue.record("could not allocate sentinel descriptor")
        return
    }
    defer { _ = close(sentinelDescriptor) }
    #expect(fcntl(sentinelDescriptor, F_SETFD, 0) == 0)

    let script = #"""
    if ( eval ': >&'"$SENTINEL_FD" ) 2>/dev/null; then
      printf inherited
    else
      printf closed
    fi
    """#
    let result = try await CodexProcessSupervisor().run(
        supervisorInvocation(
            workingDirectory: temporaryDirectory,
            script: script,
            environment: ["SENTINEL_FD": String(sentinelDescriptor)]
        )
    )

    #expect(result.termination == .exited(code: 0))
    #expect(String(data: result.standardOutput, encoding: .utf8) == "closed")
}

@Test("正常exitしたleaderをanchorに残存descendantを回収してからreapする")
func codexSupervisorCleansDescendantAfterNormalLeaderExit() async throws {
    let temporaryDirectory = try makeSupervisorTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let leaderPIDURL = temporaryDirectory.appending(path: "leader.pid")
    let descendantPIDURL = temporaryDirectory.appending(path: "descendant.pid")
    let supervisor = CodexProcessSupervisor()
    let invocation = try supervisorInvocation(
        workingDirectory: temporaryDirectory,
        script: #"""
        printf '%s' "$$" > "$LEADER_PID_FILE"
        /bin/sh -c 'trap "" TERM; printf "%s" "$$" > "$DESCENDANT_PID_FILE"; while :; do /bin/sleep 1; done' &
        while [ ! -s "$DESCENDANT_PID_FILE" ]; do /bin/sleep 0.01; done
        exit 0
        """#,
        environment: [
            "DESCENDANT_PID_FILE": descendantPIDURL.path,
            "LEADER_PID_FILE": leaderPIDURL.path
        ],
        timeout: .seconds(3),
        terminationGracePeriod: .milliseconds(80)
    )
    let task = Task { try await supervisor.run(invocation) }
    let leaderPID = try await waitForRecordedPID(
        at: leaderPIDURL,
        cancelling: supervisor,
        task: task
    )
    let leaderCleanup = SupervisorProcessIdentity.capture(processID: leaderPID)
    let watchdog = supervisorCleanupWatchdog(leaderCleanup, supervisor: supervisor)
    defer { watchdog.cancel() }
    let descendantPID = try await waitForRecordedPID(
        at: descendantPIDURL,
        cancelling: supervisor,
        task: task
    )
    let descendantCleanup = SupervisorProcessIdentity.capture(processID: descendantPID)
    let descendantWatchdog = supervisorCleanupWatchdog(descendantCleanup, supervisor: supervisor)
    defer { descendantWatchdog.cancel() }
    defer {
        leaderCleanup?.terminateIfStillMatching()
        descendantCleanup?.terminateIfStillMatching()
    }
    let error = await capturedSupervisorError {
        _ = try await task.value
    }
    #expect(error == .lingeringDescendant)
    try await expectProcessAndGroupGone(leaderPID)
    try await expectProcessGone(descendantPID)
    expectDirectChildAlreadyReaped(leaderPID)
}

@Test("既にcancel済みのconsumerはchildをspawnしない")
func codexSupervisorRejectsPreCancelledRunBeforeSpawn() async throws {
    let temporaryDirectory = try makeSupervisorTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let leaderPIDURL = temporaryDirectory.appending(path: "leader.pid")
    let supervisor = CodexProcessSupervisor()
    let invocation = try supervisorInvocation(
        workingDirectory: temporaryDirectory,
        script: "printf '%s' \"$$\" > \"$LEADER_PID_FILE\"; exec /bin/sleep 3",
        environment: ["LEADER_PID_FILE": leaderPIDURL.path]
    )
    let (gate, gateContinuation) = AsyncStream.makeStream(of: Void.self)
    let task = Task {
        var iterator = gate.makeAsyncIterator()
        _ = await iterator.next()
        return try await supervisor.run(invocation)
    }

    task.cancel()
    gateContinuation.yield(())
    gateContinuation.finish()

    let error = await capturedSupervisorError {
        _ = try await task.value
    }
    #expect(error == .cancelled)
    try await Task.sleep(for: .milliseconds(100))
    let publishedPID = try? recordedPID(at: leaderPIDURL)
    let cleanup = publishedPID.flatMap {
        SupervisorProcessIdentity.capture(processID: $0)
    }
    defer { cleanup?.terminateIfStillMatching() }
    #expect(publishedPID == nil)
}

@Test("stderrは16 KiBちょうどを受理し内容を返さずbyte countだけ返す")
func codexSupervisorAcceptsExactStandardErrorCap() async throws {
    let temporaryDirectory = try makeSupervisorTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let script = #"""
    index=0
    while [ "$index" -lt 256 ]; do
      printf 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' >&2
      index=$((index + 1))
    done
    """#

    let result = try await CodexProcessSupervisor().run(
        supervisorInvocation(
            workingDirectory: temporaryDirectory,
            script: script
        )
    )

    #expect(result.termination == .exited(code: 0))
    #expect(result.standardOutput.isEmpty)
    #expect(result.standardErrorByteCount == CodexProcessInvocation.maximumStandardErrorBytes)
}

@Test("deadline後に観測したimmediate exitを成功へ戻さずtimeoutをfirst-winsにする")
func codexSupervisorDeadlineWinsOverLateObservedExit() async throws {
    let temporaryDirectory = try makeSupervisorTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    for _ in 0 ..< 12 {
        let error = await capturedSupervisorError {
            _ = try await CodexProcessSupervisor().run(
                supervisorInvocation(
                    executablePath: "/usr/bin/true",
                    workingDirectory: temporaryDirectory,
                    timeout: .nanoseconds(1),
                    terminationGracePeriod: .milliseconds(10)
                )
            )
        }
        #expect(error == .timedOut)
    }
}

@Test("poll直後にdeadlineへ達した場合は観測済みexitよりtimeoutを優先する")
func codexSupervisorPostPollDeadlineDecisionIsFailClosed() {
    let state = CodexProcessState()
    let deadline = ContinuousClock().now
    let decision = CodexProcessRunner.resolvePolledExit(
        siginfo_t(),
        observedAt: deadline,
        deadline: deadline,
        state: state
    )

    #expect(decision.exit != nil)
    #expect(decision.deadlineReached)
    #expect(state.snapshot().stopReason == .timedOut)
    state.requestStop(.exited)
    #expect(state.snapshot().stopReason == .timedOut)
}

@Test("期限切れrequestはspawnとstdin送信を始めない")
func codexSupervisorExpiredRequestDoesNotStartInput() async throws {
    let temporaryDirectory = try makeSupervisorTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let spawnMarkerURL = temporaryDirectory.appending(path: "spawned")
    let markerURL = temporaryDirectory.appending(path: "stdin-received")

    for _ in 0 ..< 12 {
        let error = await capturedSupervisorError {
            _ = try await CodexProcessSupervisor().run(
                supervisorInvocation(
                    workingDirectory: temporaryDirectory,
                    script: #"""
                    printf spawned > "$SPAWN_MARKER_FILE"
                    IFS= read -r input
                    printf received > "$INPUT_MARKER_FILE"
                    """#,
                    environment: [
                        "INPUT_MARKER_FILE": markerURL.path,
                        "SPAWN_MARKER_FILE": spawnMarkerURL.path
                    ],
                    standardInput: Data("sensitive synthetic input\n".utf8),
                    timeout: .nanoseconds(1),
                    terminationGracePeriod: .milliseconds(10)
                )
            )
        }
        #expect(error == .timedOut)
        #expect(!FileManager.default.fileExists(atPath: spawnMarkerURL.path))
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))
    }
}

@Test("同じsupervisorの並行2件目はspawn前にalreadyRunningで拒否する")
func codexSupervisorRejectsConcurrentSecondRun() async throws {
    let temporaryDirectory = try makeSupervisorTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let leaderPIDURL = temporaryDirectory.appending(path: "leader.pid")
    let supervisor = CodexProcessSupervisor()
    let firstInvocation = try supervisorInvocation(
        workingDirectory: temporaryDirectory,
        script: #"""
        trap '' TERM
        printf '%s' "$$" > "$LEADER_PID_FILE"
        while :; do /bin/sleep 1; done
        """#,
        environment: ["LEADER_PID_FILE": leaderPIDURL.path],
        terminationGracePeriod: .milliseconds(80)
    )
    let firstTask = Task { try await supervisor.run(firstInvocation) }
    let leaderPID = try await waitForRecordedPID(
        at: leaderPIDURL,
        cancelling: supervisor,
        task: firstTask
    )
    let cleanup = SupervisorProcessIdentity.capture(processID: leaderPID)
    defer { cleanup?.terminateIfStillMatching() }
    let watchdog = supervisorCleanupWatchdog(cleanup, supervisor: supervisor)
    defer { watchdog.cancel() }

    let secondError = await capturedSupervisorError {
        _ = try await supervisor.run(
            supervisorInvocation(
                executablePath: "/usr/bin/true",
                workingDirectory: temporaryDirectory
            )
        )
    }
    #expect(secondError == .alreadyRunning)

    await supervisor.cancel()
    let firstError = await capturedSupervisorError {
        _ = try await firstTask.value
    }
    #expect(firstError == .cancelled)
    try await expectProcessAndGroupGone(leaderPID)
    expectDirectChildAlreadyReaped(leaderPID)
}
