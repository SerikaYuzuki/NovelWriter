import Darwin
import Foundation

#if !FUMINIWA_ENABLE_EXPERIMENTAL_AI
#error("Codex process supervision must only compile in FUMINIWAExperimental")
#endif

extension CodexProcessRunner {
    static func run(
        _ invocation: CodexProcessInvocation,
        state: CodexProcessState
    ) throws -> CodexProcessResult {
        if let reason = state.snapshot().stopReason {
            throw supervisorError(for: reason)
        }

        let timeoutDeadline = ContinuousClock().now.advanced(by: invocation.timeout)
        let execution = try startExecution(
            invocation,
            timeoutDeadline: timeoutDeadline,
            state: state
        )
        var anchoredExit: siginfo_t?
        do {
            anchoredExit = try waitForExitOrStop(
                processID: execution.processID,
                deadline: execution.timeoutDeadline,
                state: state
            )
            let waitStatus = try terminateAndReap(
                processID: execution.processID,
                gracePeriod: invocation.terminationGracePeriod,
                anchoredExit: &anchoredExit,
                state: state
            )
            try execution.processIO.finish(gracePeriod: invocation.terminationGracePeriod)
            return try makeResult(
                waitStatus: waitStatus,
                processIO: execution.processIO,
                state: state
            )
        } catch {
            let originalError = normalizedSupervisorError(error)
            state.requestStop(.failure(originalError))
            let cleanupError = cleanupAfterFailure(
                processID: execution.processID,
                gracePeriod: invocation.terminationGracePeriod,
                anchoredExit: &anchoredExit,
                state: state
            )
            let ioError = finishIO(
                execution.processIO,
                gracePeriod: invocation.terminationGracePeriod
            )
            let claimedError = claimedFailure(
                for: state.snapshot().stopReason
            )
            let ioSafetyError = ioWorkerSafetyError(ioError)
                ?? ioWorkerSafetyError(originalError)
            throw cleanupError ?? ioSafetyError ?? claimedError ?? originalError
        }
    }

    private static func startExecution(
        _ invocation: CodexProcessInvocation,
        timeoutDeadline: ContinuousClock.Instant,
        state: CodexProcessState
    ) throws -> CodexProcessExecution {
        var pipes = try CodexProcessPipes()
        do {
            try pipes.configureParentEnds()
            if let reason = state.stopReason(
                claimingTimeoutAt: timeoutDeadline
            ) {
                throw supervisorError(for: reason)
            }
            let processID = try spawn(invocation, pipes: pipes)
            state.install(processID: processID)
            _ = state.stopReason(claimingTimeoutAt: timeoutDeadline)
            let processIO = pipes.transferParentEndsToIO(
                input: invocation.standardInput,
                deadline: timeoutDeadline,
                state: state
            )
            return CodexProcessExecution(
                processID: processID,
                timeoutDeadline: timeoutDeadline,
                processIO: processIO
            )
        } catch {
            pipes.closeAll()
            throw error
        }
    }

    private static func makeResult(
        waitStatus: Int32,
        processIO: CodexProcessIO,
        state: CodexProcessState
    ) throws -> CodexProcessResult {
        if state.snapshot().stopReason == nil {
            state.requestStop(.exited)
        }
        let reason = state.snapshot().stopReason ?? .failure(.invalidWaitStatus)
        guard case .exited = reason else {
            throw supervisorError(for: reason)
        }
        if let failure = processIO.failure {
            throw failure
        }
        return try CodexProcessResult(
            standardOutput: processIO.standardOutput,
            standardErrorByteCount: processIO.standardErrorByteCount,
            termination: termination(from: waitStatus)
        )
    }

    private static func normalizedSupervisorError(
        _ error: any Error
    ) -> CodexProcessSupervisorError {
        error as? CodexProcessSupervisorError ?? .invalidWaitStatus
    }

    private static func finishIO(
        _ processIO: CodexProcessIO,
        gracePeriod: Duration
    ) -> CodexProcessSupervisorError? {
        do {
            try processIO.finish(gracePeriod: gracePeriod)
            return nil
        } catch let error as CodexProcessSupervisorError {
            return error
        } catch {
            return .invalidWaitStatus
        }
    }

    private static func claimedFailure(
        for reason: CodexProcessSession.StopReason?
    ) -> CodexProcessSupervisorError? {
        switch reason {
        case .cancelled, .timedOut, .failure:
            reason.map(supervisorError)
        case .exited, nil:
            nil
        }
    }

    private static func ioWorkerSafetyError(
        _ error: CodexProcessSupervisorError?
    ) -> CodexProcessSupervisorError? {
        guard error == .ioWorkersFailedToStop else { return nil }
        return error
    }

    static func supervisorError(
        for reason: CodexProcessSession.StopReason
    ) -> CodexProcessSupervisorError {
        switch reason {
        case .exited:
            .invalidWaitStatus
        case .cancelled:
            .cancelled
        case .timedOut:
            .timedOut
        case let .failure(error):
            error
        }
    }
}

private struct CodexProcessExecution {
    let processID: pid_t
    let timeoutDeadline: ContinuousClock.Instant
    let processIO: CodexProcessIO
}
