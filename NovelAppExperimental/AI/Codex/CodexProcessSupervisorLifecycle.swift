import Darwin
import Foundation

#if !FUMINIWA_ENABLE_EXPERIMENTAL_AI
#error("Codex process supervision must only compile in FUMINIWAExperimental")
#endif

extension CodexProcessRunner {
    static func waitForExitOrStop(
        processID: pid_t,
        deadline: ContinuousClock.Instant,
        state: CodexProcessState
    ) throws -> siginfo_t? {
        let clock = ContinuousClock()
        while true {
            if state.snapshot().stopReason != nil {
                return nil
            }
            guard clock.now < deadline else {
                state.requestStop(.timedOut)
                return nil
            }
            let exit = try pollDirectChildExit(processID, state: state)
            let decision = resolvePolledExit(
                exit,
                observedAt: clock.now,
                deadline: deadline,
                state: state
            )
            if decision.deadlineReached {
                return decision.exit
            }
            if let exit = decision.exit {
                return exit
            }
            sleepBriefly()
        }
    }

    static func resolvePolledExit(
        _ exit: siginfo_t?,
        observedAt: ContinuousClock.Instant,
        deadline: ContinuousClock.Instant,
        state: CodexProcessState
    ) -> (exit: siginfo_t?, deadlineReached: Bool) {
        let deadlineReached = observedAt >= deadline
        if deadlineReached {
            state.requestStop(.timedOut)
        }
        return (exit, deadlineReached)
    }

    static func terminateAndReap(
        processID: pid_t,
        gracePeriod: Duration,
        anchoredExit: inout siginfo_t?,
        state: CodexProcessState
    ) throws -> Int32 {
        try requireDirectChildOwnership(state)
        if anchoredExit == nil {
            anchoredExit = try pollDirectChildExit(processID, state: state)
        }

        try claimNaturalExitOrLingeringDescendant(
            processID: processID,
            anchoredExit: anchoredExit,
            state: state
        )
        let cleanupDeadline = ContinuousClock().now
            .advanced(by: gracePeriod + .seconds(2))
        if shouldTerminateGroup(state.snapshot().stopReason) {
            try terminateProcessGroup(
                processID: processID,
                gracePeriod: gracePeriod,
                cleanupDeadline: cleanupDeadline,
                anchoredExit: &anchoredExit,
                state: state
            )
        }

        if anchoredExit == nil {
            anchoredExit = try waitForDirectChildExit(
                processID,
                deadline: cleanupDeadline,
                state: state
            )
        }
        let waitStatus = try reapDirectChild(
            processID,
            deadline: cleanupDeadline,
            state: state
        )
        try verifyProcessGroupEmptyAfterReap(
            processID,
            deadline: cleanupDeadline
        )
        return waitStatus
    }

    static func cleanupAfterFailure(
        processID: pid_t,
        gracePeriod: Duration,
        anchoredExit: inout siginfo_t?,
        state: CodexProcessState
    ) -> CodexProcessSupervisorError? {
        let snapshot = state.snapshot()
        if snapshot.directChildOwnershipLost {
            return .systemCallFailed(operation: "waitid(ownership lost)", code: ECHILD)
        }
        if snapshot.isReaped {
            do {
                try verifyProcessGroupEmptyAfterReap(
                    processID,
                    deadline: ContinuousClock().now.advanced(by: .seconds(1))
                )
                return nil
            } catch {
                return normalizedLifecycleError(error)
            }
        }

        do {
            _ = try terminateAndReap(
                processID: processID,
                gracePeriod: gracePeriod,
                anchoredExit: &anchoredExit,
                state: state
            )
            return nil
        } catch {
            let firstError = normalizedLifecycleError(error)
            do {
                try emergencyKillAndReap(
                    processID,
                    anchoredExit: &anchoredExit,
                    state: state
                )
                return nil
            } catch {
                return normalizedLifecycleError(error, fallback: firstError)
            }
        }
    }

    static func termination(
        from waitStatus: Int32
    ) throws -> CodexProcessResult.Termination {
        let signal = waitStatus & 0x7F
        if signal == 0 {
            return .exited(code: (waitStatus >> 8) & 0xFF)
        }
        guard signal != 0x7F else {
            throw CodexProcessSupervisorError.invalidWaitStatus
        }
        return .signaled(signal: signal)
    }

    static func sleepBriefly() {
        var request = timespec(tv_sec: 0, tv_nsec: 2_000_000)
        var remainder = timespec()
        var interruptedAttempts = 0
        while interruptedAttempts < 4 {
            guard nanosleep(&request, &remainder) == -1, errno == EINTR else {
                break
            }
            request = remainder
            interruptedAttempts += 1
        }
    }
}

extension CodexProcessRunner {
    enum ProcessGroupProbe: Equatable {
        case liveMembers
        case zombieAnchorOnly
        case permissionDenied
        case empty
    }

    static func pollDirectChildExit(
        _ processID: pid_t,
        state: CodexProcessState
    ) throws -> siginfo_t? {
        var information = siginfo_t()
        errno = 0
        let result = waitid(
            P_PID,
            id_t(processID),
            &information,
            WEXITED | WNOHANG | WNOWAIT
        )
        if result == 0 {
            return information.si_pid == processID ? information : nil
        }
        let code = errno
        if code == EINTR {
            return nil
        }
        if code == ECHILD {
            state.markDirectChildOwnershipLost()
        }
        throw CodexProcessSupervisorError.systemCallFailed(
            operation: "waitid(WNOWAIT)",
            code: code
        )
    }

    static func claimNaturalExitOrLingeringDescendant(
        processID: pid_t,
        anchoredExit: siginfo_t?,
        state: CodexProcessState
    ) throws {
        guard state.snapshot().stopReason == nil, anchoredExit != nil else {
            return
        }
        switch try probeProcessGroup(processID, hasAnchoredExit: true) {
        case .liveMembers:
            state.requestStop(.failure(.lingeringDescendant))
        case .zombieAnchorOnly, .empty:
            state.requestStop(.exited)
        case .permissionDenied:
            throw CodexProcessSupervisorError.processGroupNotEmpty(code: EPERM)
        }
    }

    static func shouldTerminateGroup(
        _ reason: CodexProcessSession.StopReason?
    ) -> Bool {
        switch reason {
        case .cancelled, .timedOut, .failure:
            true
        case .exited, nil:
            false
        }
    }

    static func terminateProcessGroup(
        processID: pid_t,
        gracePeriod: Duration,
        cleanupDeadline: ContinuousClock.Instant,
        anchoredExit: inout siginfo_t?,
        state: CodexProcessState
    ) throws {
        try requireDirectChildOwnership(state)
        guard try sendSignalIfGroupIsLive(
            SIGTERM,
            processID: processID,
            anchoredExit: &anchoredExit,
            state: state
        ) else {
            return
        }

        let graceDeadline = ContinuousClock().now.advanced(by: gracePeriod)
        if try waitUntilGroupHasNoLiveMembers(
            processID,
            deadline: graceDeadline,
            anchoredExit: &anchoredExit,
            state: state
        ) {
            return
        }
        guard try sendSignalIfGroupIsLive(
            SIGKILL,
            processID: processID,
            anchoredExit: &anchoredExit,
            state: state
        ) else {
            return
        }
        guard try waitUntilGroupHasNoLiveMembers(
            processID,
            deadline: cleanupDeadline,
            anchoredExit: &anchoredExit,
            state: state
        ) else {
            throw CodexProcessSupervisorError.processGroupNotEmpty(code: 0)
        }
    }

    static func sendSignalIfGroupIsLive(
        _ signal: Int32,
        processID: pid_t,
        anchoredExit: inout siginfo_t?,
        state: CodexProcessState
    ) throws -> Bool {
        try requireDirectChildOwnership(state)
        let probe = try probeProcessGroupRecoveringAnchor(
            processID,
            recoveryDeadline: ContinuousClock().now.advanced(by: .milliseconds(100)),
            anchoredExit: &anchoredExit,
            state: state
        )
        if probe == .empty, anchoredExit == nil {
            anchoredExit = try pollDirectChildExit(processID, state: state)
            guard anchoredExit == nil else { return false }
            return try sendDirectSignal(signal, processID: processID)
        }
        guard probe == .liveMembers else {
            if probe == .permissionDenied {
                throw CodexProcessSupervisorError.processGroupSignalFailed(
                    signal: signal,
                    code: EPERM
                )
            }
            return false
        }

        errno = 0
        if kill(-processID, signal) == 0 {
            return true
        }
        let code = errno
        if code == ESRCH {
            return false
        }
        if code == EPERM, anchoredExit == nil {
            anchoredExit = try pollDirectChildExit(processID, state: state)
            if anchoredExit != nil {
                let retryProbe = try probeProcessGroup(
                    processID,
                    hasAnchoredExit: true
                )
                if retryProbe != .liveMembers {
                    return false
                }
            }
        }
        throw CodexProcessSupervisorError.processGroupSignalFailed(
            signal: signal,
            code: code
        )
    }

    static func sendDirectSignal(
        _ signal: Int32,
        processID: pid_t
    ) throws -> Bool {
        errno = 0
        if kill(processID, signal) == 0 {
            return true
        }
        if errno == ESRCH {
            return false
        }
        throw CodexProcessSupervisorError.processGroupSignalFailed(
            signal: signal,
            code: errno
        )
    }

    static func probeProcessGroupRecoveringAnchor(
        _ processID: pid_t,
        recoveryDeadline: ContinuousClock.Instant,
        anchoredExit: inout siginfo_t?,
        state: CodexProcessState
    ) throws -> ProcessGroupProbe {
        var probe = try probeProcessGroup(
            processID,
            hasAnchoredExit: anchoredExit != nil
        )
        let clock = ContinuousClock()
        while probe == .permissionDenied, anchoredExit == nil {
            guard clock.now < recoveryDeadline else { break }
            anchoredExit = try pollDirectChildExit(processID, state: state)
            probe = try probeProcessGroup(
                processID,
                hasAnchoredExit: anchoredExit != nil
            )
            if probe == .permissionDenied, anchoredExit == nil {
                sleepBriefly()
            }
        }
        return probe
    }

    static func normalizedLifecycleError(
        _ error: any Error,
        fallback: CodexProcessSupervisorError = .invalidWaitStatus
    ) -> CodexProcessSupervisorError {
        error as? CodexProcessSupervisorError ?? fallback
    }
}
