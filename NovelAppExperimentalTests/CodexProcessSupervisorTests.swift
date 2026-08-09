import Darwin
import Foundation
@testable import FUMINIWAExperimental
import Testing

@Test("posix_spawn childへstdin・cwd・exact environmentを渡しstdout・stderr・exitを返す")
func codexSupervisorUsesExactInvocationAndDrainsPipes() async throws {
    let temporaryDirectory = try makeSupervisorTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let environment = [
        "FUMINIWA_EXACT_ALPHA": "alpha value",
        "FUMINIWA_EXACT_OMEGA": "終端"
    ]
    let environmentResult = try await CodexProcessSupervisor().run(
        supervisorInvocation(
            executablePath: "/usr/bin/env",
            workingDirectory: temporaryDirectory,
            environment: environment
        )
    )
    #expect(environmentResult.termination == .exited(code: 0))
    #expect(environmentResult.standardErrorByteCount == 0)
    #expect(environmentLines(environmentResult.standardOutput) == environment)

    let script = #"""
    IFS= read -r input
    /bin/pwd
    printf 'stdin:%s\n' "$input"
    printf 'stderr:%s\n' "$FUMINIWA_EXACT_ALPHA" >&2
    exit 23
    """#
    let result = try await CodexProcessSupervisor().run(
        supervisorInvocation(
            workingDirectory: temporaryDirectory,
            script: script,
            environment: environment,
            standardInput: Data("synthetic input\n".utf8)
        )
    )

    #expect(result.termination == .exited(code: 23))
    let standardOutput = String(data: result.standardOutput, encoding: .utf8)
    let physicalWorkingDirectory = try physicalPath(for: temporaryDirectory)
    #expect(standardOutput == "\(physicalWorkingDirectory)\nstdin:synthetic input\n")
    #expect(result.standardErrorByteCount == "stderr:alpha value\n".utf8.count)
}

@Test("stdoutとstderrを同時に上限内でdrainしdeadlockしない")
func codexSupervisorDrainsStandardOutputAndErrorConcurrently() async throws {
    let temporaryDirectory = try makeSupervisorTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let script = #"""
    index=0
    while [ "$index" -lt 8192 ]; do
      printf 'oooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooo'
      printf 'ee' >&2
      index=$((index + 1))
    done
    """#
    let result = try await CodexProcessSupervisor().run(
        supervisorInvocation(
            workingDirectory: temporaryDirectory,
            script: script,
            timeout: .seconds(5)
        )
    )

    #expect(result.termination == .exited(code: 0))
    #expect(result.standardOutput.count == CodexProcessInvocation.maximumStandardOutputBytes)
    #expect(result.standardErrorByteCount == CodexProcessInvocation.maximumStandardErrorBytes)
    #expect(result.standardOutput.allSatisfy { $0 == 0x6F })
}

@Test("signal終了はexit codeへ偽装せずsignaled terminalとして一度だけ返す")
func codexSupervisorReturnsSignalTermination() async throws {
    let temporaryDirectory = try makeSupervisorTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

    let result = try await CodexProcessSupervisor().run(
        supervisorInvocation(
            workingDirectory: temporaryDirectory,
            script: "kill -TERM $$"
        )
    )

    #expect(result.termination == .signaled(signal: SIGTERM))
    #expect(result.standardOutput.isEmpty)
    #expect(result.standardErrorByteCount == 0)
}

@Test("stdinは512 KiBちょうどを許可し1 byte超過をspawn前に拒否する")
func codexSupervisorEnforcesStandardInputCap() async throws {
    let temporaryDirectory = try makeSupervisorTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let maximumInput = Data(
        repeating: 0x78,
        count: CodexProcessInvocation.maximumStandardInputBytes
    )

    let result = try await CodexProcessSupervisor().run(
        supervisorInvocation(
            executablePath: "/bin/cat",
            workingDirectory: temporaryDirectory,
            standardInput: maximumInput,
            timeout: .seconds(5)
        )
    )
    #expect(result.termination == .exited(code: 0))
    #expect(result.standardOutput == maximumInput)
    #expect(result.standardErrorByteCount == 0)

    do {
        _ = try supervisorInvocation(
            workingDirectory: temporaryDirectory,
            standardInput: Data(
                repeating: 0x78,
                count: CodexProcessInvocation.maximumStandardInputBytes + 1
            )
        )
        Issue.record("expected standardInputLimitExceeded")
    } catch let error as CodexProcessSupervisorError {
        #expect(
            error == .standardInputLimitExceeded(
                limit: CodexProcessInvocation.maximumStandardInputBytes,
                actual: CodexProcessInvocation.maximumStandardInputBytes + 1
            )
        )
    }
}

@Test("stdinを読まず終了したchildへのwriteはSIGPIPEでhostを落とさずtyped EPIPEにする")
func codexSupervisorTurnsClosedStandardInputIntoTypedFailure() async throws {
    let temporaryDirectory = try makeSupervisorTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let input = Data(
        repeating: 0x78,
        count: CodexProcessInvocation.maximumStandardInputBytes
    )

    let error = await capturedSupervisorError {
        _ = try await CodexProcessSupervisor().run(
            supervisorInvocation(
                workingDirectory: temporaryDirectory,
                script: "exit 0",
                standardInput: input
            )
        )
    }
    #expect(error == .inputWriteFailed(code: EPIPE))
}

@Test("wall timeoutはTERMを無視するleaderをKILLしdirect childをreapしてgroupを空にする")
func codexSupervisorTimeoutKillsReapsAndEmptiesGroup() async throws {
    let temporaryDirectory = try makeSupervisorTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let leaderPIDURL = temporaryDirectory.appending(path: "leader.pid")

    let supervisor = CodexProcessSupervisor()
    let invocation = try supervisorInvocation(
        workingDirectory: temporaryDirectory,
        script: #"""
        trap '' TERM
        printf '%s' "$$" > "$LEADER_PID_FILE"
        while :; do /bin/sleep 1; done
        """#,
        environment: ["LEADER_PID_FILE": leaderPIDURL.path],
        timeout: .milliseconds(150),
        terminationGracePeriod: .milliseconds(80)
    )

    let task = Task { try await supervisor.run(invocation) }
    let leaderPID = try await waitForRecordedPID(
        at: leaderPIDURL,
        cancelling: supervisor,
        task: task
    )
    let cleanup = SupervisorProcessIdentity.capture(processID: leaderPID)
    defer { cleanup?.terminateIfStillMatching() }
    let watchdog = supervisorCleanupWatchdog(cleanup, supervisor: supervisor)
    defer { watchdog.cancel() }

    let error = await capturedSupervisorError {
        _ = try await task.value
    }
    #expect(error == .timedOut)

    try await expectProcessAndGroupGone(leaderPID)
    expectDirectChildAlreadyReaped(leaderPID)
}

@Test("consumer cancelと重複cancelは一つのcancelled terminalでcleanup完了後に返る")
func codexSupervisorConsumerAndDuplicateCancellationAreIdempotent() async throws {
    let temporaryDirectory = try makeSupervisorTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let leaderPIDURL = temporaryDirectory.appending(path: "leader.pid")

    let supervisor = CodexProcessSupervisor()
    let invocation = try supervisorInvocation(
        workingDirectory: temporaryDirectory,
        script: #"""
        trap '' TERM
        printf '%s' "$$" > "$LEADER_PID_FILE"
        while :; do /bin/sleep 1; done
        """#,
        environment: ["LEADER_PID_FILE": leaderPIDURL.path],
        timeout: .seconds(3),
        terminationGracePeriod: .milliseconds(80)
    )
    let task = Task { try await supervisor.run(invocation) }
    let leaderPID = try await waitForRecordedPID(
        at: leaderPIDURL,
        cancelling: supervisor,
        task: task
    )
    let cleanup = SupervisorProcessIdentity.capture(processID: leaderPID)
    defer { cleanup?.terminateIfStillMatching() }
    let watchdog = supervisorCleanupWatchdog(cleanup, supervisor: supervisor)
    defer { watchdog.cancel() }

    task.cancel()
    async let firstCancel: Void = supervisor.cancel()
    async let secondCancel: Void = supervisor.cancel()
    _ = await (firstCancel, secondCancel)

    let error = await capturedSupervisorError {
        _ = try await task.value
    }
    #expect(error == .cancelled)
    try await expectProcessAndGroupGone(leaderPID)
    expectDirectChildAlreadyReaped(leaderPID)
}

@Test("timeoutはTERMを無視する同一groupのdescendantもKILLして残さない")
func codexSupervisorKillsDescendantProcessGroup() async throws {
    let temporaryDirectory = try makeSupervisorTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let leaderPIDURL = temporaryDirectory.appending(path: "leader.pid")
    let descendantPIDURL = temporaryDirectory.appending(path: "descendant.pid")

    let invocation = try supervisorInvocation(
        workingDirectory: temporaryDirectory,
        script: #"""
        trap '' TERM
        /bin/sh -c 'trap "" TERM; printf "%s" "$$" > "$DESCENDANT_PID_FILE"; while :; do /bin/sleep 1; done' &
        printf '%s' "$$" > "$LEADER_PID_FILE"
        wait
        """#,
        environment: [
            "DESCENDANT_PID_FILE": descendantPIDURL.path,
            "LEADER_PID_FILE": leaderPIDURL.path
        ],
        timeout: .milliseconds(250),
        terminationGracePeriod: .milliseconds(80)
    )
    let supervisor = CodexProcessSupervisor()
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
    #expect(error == .timedOut)
    try await expectProcessAndGroupGone(leaderPID)
    try await expectProcessGone(descendantPID)
    expectDirectChildAlreadyReaped(leaderPID)
}

@Test("stdout capを1 byteでも超えるとtyped failureでprocess groupを回収する")
func codexSupervisorRejectsStandardOutputAboveCap() async throws {
    let temporaryDirectory = try makeSupervisorTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let leaderPIDURL = temporaryDirectory.appending(path: "leader.pid")

    let supervisor = CodexProcessSupervisor()
    let task = Task {
        try await supervisor.run(
            supervisorInvocation(
                workingDirectory: temporaryDirectory,
                script: #"""
                printf '%s' "$$" > "$LEADER_PID_FILE"
                index=0
                while [ "$index" -lt 8192 ]; do
                  printf 'oooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooo'
                  index=$((index + 1))
                done
                printf o
                """#,
                environment: ["LEADER_PID_FILE": leaderPIDURL.path],
                timeout: .seconds(3)
            )
        )
    }
    let leaderPID = try await waitForRecordedPID(
        at: leaderPIDURL,
        cancelling: supervisor,
        task: task
    )
    let cleanup = SupervisorProcessIdentity.capture(processID: leaderPID)
    defer { cleanup?.terminateIfStillMatching() }
    let watchdog = supervisorCleanupWatchdog(cleanup, supervisor: supervisor)
    defer { watchdog.cancel() }

    let error = await capturedSupervisorError {
        _ = try await task.value
    }
    guard case let .standardOutputLimitExceeded(limit, actualAtLeast) = error else {
        Issue.record("expected standardOutputLimitExceeded, got \(String(describing: error))")
        return
    }
    #expect(limit == CodexProcessInvocation.maximumStandardOutputBytes)
    #expect(actualAtLeast == limit + 1)
    try await expectProcessAndGroupGone(leaderPID)
    expectDirectChildAlreadyReaped(leaderPID)
}

@Test("stderr capを1 byteでも超えるとtyped failureでprocess groupを回収する")
func codexSupervisorRejectsStandardErrorAboveCap() async throws {
    let temporaryDirectory = try makeSupervisorTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let leaderPIDURL = temporaryDirectory.appending(path: "leader.pid")

    let supervisor = CodexProcessSupervisor()
    let task = Task {
        try await supervisor.run(
            supervisorInvocation(
                workingDirectory: temporaryDirectory,
                script: #"""
                printf '%s' "$$" > "$LEADER_PID_FILE"
                index=0
                while [ "$index" -lt 256 ]; do
                  printf 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' >&2
                  index=$((index + 1))
                done
                printf e >&2
                """#,
                environment: ["LEADER_PID_FILE": leaderPIDURL.path],
                timeout: .seconds(3)
            )
        )
    }
    let leaderPID = try await waitForRecordedPID(
        at: leaderPIDURL,
        cancelling: supervisor,
        task: task
    )
    let cleanup = SupervisorProcessIdentity.capture(processID: leaderPID)
    defer { cleanup?.terminateIfStillMatching() }
    let watchdog = supervisorCleanupWatchdog(cleanup, supervisor: supervisor)
    defer { watchdog.cancel() }

    let error = await capturedSupervisorError {
        _ = try await task.value
    }
    guard case let .standardErrorLimitExceeded(limit, actualAtLeast) = error else {
        Issue.record("expected standardErrorLimitExceeded, got \(String(describing: error))")
        return
    }
    #expect(limit == CodexProcessInvocation.maximumStandardErrorBytes)
    #expect(actualAtLeast == limit + 1)
    try await expectProcessAndGroupGone(leaderPID)
    expectDirectChildAlreadyReaped(leaderPID)
}
