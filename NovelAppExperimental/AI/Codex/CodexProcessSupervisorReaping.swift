import Darwin
import Foundation

#if !FUMINIWA_ENABLE_EXPERIMENTAL_AI
#error("Codex process supervision must only compile in FUMINIWAExperimental")
#endif

extension CodexProcessRunner {
    static func waitUntilGroupHasNoLiveMembers(
        _ processID: pid_t,
        deadline: ContinuousClock.Instant,
        anchoredExit: inout siginfo_t?,
        state: CodexProcessState
    ) throws -> Bool {
        let clock = ContinuousClock()
        while clock.now < deadline {
            if anchoredExit == nil {
                anchoredExit = try pollDirectChildExit(processID, state: state)
            }
            let probe = try probeProcessGroupRecoveringAnchor(
                processID,
                recoveryDeadline: deadline,
                anchoredExit: &anchoredExit,
                state: state
            )
            switch probe {
            case .zombieAnchorOnly, .empty:
                return true
            case .permissionDenied:
                throw CodexProcessSupervisorError.processGroupNotEmpty(code: EPERM)
            case .liveMembers:
                break
            }
            sleepBriefly()
        }
        return false
    }

    static func probeProcessGroup(
        _ processID: pid_t,
        hasAnchoredExit: Bool
    ) throws -> ProcessGroupProbe {
        errno = 0
        if kill(-processID, 0) == 0 {
            return .liveMembers
        }
        switch errno {
        case ESRCH:
            return .empty
        case EPERM where hasAnchoredExit:
            return .zombieAnchorOnly
        case EPERM:
            return .permissionDenied
        default:
            throw CodexProcessSupervisorError.processGroupNotEmpty(code: errno)
        }
    }

    static func waitForDirectChildExit(
        _ processID: pid_t,
        deadline: ContinuousClock.Instant,
        state: CodexProcessState
    ) throws -> siginfo_t {
        let clock = ContinuousClock()
        while clock.now < deadline {
            if let exit = try pollDirectChildExit(processID, state: state) {
                return exit
            }
            sleepBriefly()
        }
        throw CodexProcessSupervisorError.processExitTimedOut
    }

    static func reapDirectChild(
        _ processID: pid_t,
        deadline: ContinuousClock.Instant,
        state: CodexProcessState
    ) throws -> Int32 {
        try requireDirectChildOwnership(state)
        let clock = ContinuousClock()
        var waitStatus: Int32 = 0
        while clock.now < deadline {
            errno = 0
            let result = waitpid(processID, &waitStatus, WNOHANG)
            if result == processID {
                state.markReaped()
                return waitStatus
            }
            if result == -1 {
                let code = errno
                if code == EINTR {
                    continue
                }
                if code == ECHILD {
                    state.markDirectChildOwnershipLost()
                }
                throw CodexProcessSupervisorError.systemCallFailed(
                    operation: "waitpid",
                    code: code
                )
            }
            sleepBriefly()
        }
        throw CodexProcessSupervisorError.processExitTimedOut
    }

    static func verifyProcessGroupEmptyAfterReap(
        _ processID: pid_t,
        deadline: ContinuousClock.Instant
    ) throws {
        let clock = ContinuousClock()
        var latestCode = Int32(0)
        while clock.now < deadline {
            errno = 0
            if kill(-processID, 0) == -1, errno == ESRCH {
                return
            }
            latestCode = errno
            sleepBriefly()
        }
        throw CodexProcessSupervisorError.processGroupNotEmpty(code: latestCode)
    }

    static func emergencyKillAndReap(
        _ processID: pid_t,
        anchoredExit: inout siginfo_t?,
        state: CodexProcessState
    ) throws {
        try requireDirectChildOwnership(state)
        guard !state.snapshot().isReaped else {
            try verifyProcessGroupEmptyAfterReap(
                processID,
                deadline: ContinuousClock().now.advanced(by: .seconds(1))
            )
            return
        }
        _ = try sendSignalIfGroupIsLive(
            SIGKILL,
            processID: processID,
            anchoredExit: &anchoredExit,
            state: state
        )
        let deadline = ContinuousClock().now.advanced(by: .seconds(1))
        if anchoredExit == nil {
            anchoredExit = try waitForDirectChildExit(
                processID,
                deadline: deadline,
                state: state
            )
        }
        _ = try reapDirectChild(processID, deadline: deadline, state: state)
        try verifyProcessGroupEmptyAfterReap(processID, deadline: deadline)
    }

    static func requireDirectChildOwnership(
        _ state: CodexProcessState
    ) throws {
        guard !state.snapshot().directChildOwnershipLost else {
            throw CodexProcessSupervisorError.systemCallFailed(
                operation: "direct child ownership",
                code: ECHILD
            )
        }
    }
}
