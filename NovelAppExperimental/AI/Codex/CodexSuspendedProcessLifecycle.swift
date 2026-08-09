import Darwin
import Foundation

#if !FUMINIWA_ENABLE_EXPERIMENTAL_AI
#error("Codex suspended-process inspection must only compile in FUMINIWAExperimental")
#endif

private struct CodexSuspendedReapResult {
    let reaped: Bool
    let exceededPollingDeadline: Bool
    let error: CodexSuspendedProcessIdentityInspectionError?
}

final class CodexSuspendedProcessLifecycleState: @unchecked Sendable {
    enum StopReason: Sendable, Equatable {
        case cancelled
        case timedOut
    }

    private let condition = NSCondition()
    private var stopReason: StopReason?
    private var processID: pid_t?
    private var cleanupClaimed = false
    private var cleanupFinished = false
    private var cleanupError: CodexSuspendedProcessIdentityInspectionError?
    private var reaped = false

    func requestCancellation() {
        condition.withLock {
            if stopReason == nil {
                stopReason = .cancelled
            }
            condition.broadcast()
        }
    }

    func install(processID: pid_t) {
        condition.withLock {
            self.processID = processID
            condition.broadcast()
        }
    }

    func requireInspectionAllowed(
        deadline: ContinuousClock.Instant
    ) throws {
        let reason = condition.withLock { () -> StopReason? in
            if stopReason == nil, ContinuousClock().now >= deadline {
                stopReason = .timedOut
                condition.broadcast()
            }
            return stopReason
        }
        switch reason {
        case .cancelled:
            throw CodexSuspendedProcessIdentityInspectionError.cancelled
        case .timedOut:
            throw CodexSuspendedProcessIdentityInspectionError.timedOut
        case nil:
            return
        }
    }

    func claimCleanup() -> pid_t? {
        condition.withLock {
            guard !cleanupClaimed, !cleanupFinished, let processID else { return nil }
            cleanupClaimed = true
            condition.broadcast()
            return processID
        }
    }

    func performClaimedCleanup(processID: pid_t) {
        let killError = deliverKill(to: processID)
        let reapResult = reapDirectChild(processID)
        var firstError = killError ?? reapResult.error
        if reapResult.exceededPollingDeadline, firstError == nil {
            firstError = .directChildReapTimedOut
        }
        completeCleanup(reaped: reapResult.reaped, error: firstError)
    }

    private func deliverKill(
        to processID: pid_t
    ) -> CodexSuspendedProcessIdentityInspectionError? {
        let killDeadline = ContinuousClock().now.advanced(by: .milliseconds(100))
        var lastError = EPERM
        repeat {
            errno = 0
            if Darwin.kill(processID, SIGKILL) == 0 || errno == ESRCH {
                return nil
            }
            lastError = errno
            CodexProcessRunner.sleepBriefly()
        } while ContinuousClock().now < killDeadline
        return .systemCallFailed(
            operation: "kill(suspended child)",
            code: lastError
        )
    }

    private func reapDirectChild(
        _ processID: pid_t
    ) -> CodexSuspendedReapResult {
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        var waitStatus = Int32(0)
        while ContinuousClock().now < deadline {
            errno = 0
            let result = Darwin.waitpid(processID, &waitStatus, WNOHANG)
            if result == processID {
                return CodexSuspendedReapResult(
                    reaped: true,
                    exceededPollingDeadline: false,
                    error: nil
                )
            }
            if result == -1 {
                let code = errno
                if code == EINTR {
                    continue
                }
                let error = CodexSuspendedProcessIdentityInspectionError.systemCallFailed(
                    operation: "waitpid(suspended child)",
                    code: code
                )
                let blocking = waitUntilDirectChildIsReaped(processID)
                return CodexSuspendedReapResult(
                    reaped: blocking.reaped,
                    exceededPollingDeadline: false,
                    error: error
                )
            }
            CodexProcessRunner.sleepBriefly()
        }
        let blocking = waitUntilDirectChildIsReaped(processID)
        return CodexSuspendedReapResult(
            reaped: blocking.reaped,
            exceededPollingDeadline: true,
            error: blocking.error
        )
    }

    private func waitUntilDirectChildIsReaped(
        _ processID: pid_t
    ) -> (
        reaped: Bool,
        error: CodexSuspendedProcessIdentityInspectionError?
    ) {
        var waitStatus = Int32(0)
        while true {
            errno = 0
            let result = Darwin.waitpid(processID, &waitStatus, 0)
            if result == processID {
                return (true, nil)
            }
            if result == -1 {
                let code = errno
                if code == EINTR {
                    continue
                }
                return (
                    false,
                    .systemCallFailed(
                        operation: "waitpid(suspended child)",
                        code: code
                    )
                )
            }
        }
    }

    func waitForCleanup() throws {
        let result = condition.withLock { () -> (
            reaped: Bool,
            error: CodexSuspendedProcessIdentityInspectionError?
        ) in
            while !cleanupFinished {
                condition.wait()
            }
            return (reaped, cleanupError)
        }
        if let error = result.error {
            throw error
        }
        guard result.reaped else {
            throw CodexSuspendedProcessIdentityInspectionError.directChildReapTimedOut
        }
    }

    private func completeCleanup(
        reaped: Bool,
        error: CodexSuspendedProcessIdentityInspectionError?
    ) {
        condition.withLock {
            self.reaped = reaped
            cleanupError = error
            cleanupFinished = true
            condition.broadcast()
        }
    }

    func terminalError() -> CodexSuspendedProcessIdentityInspectionError? {
        condition.withLock {
            switch stopReason {
            case .cancelled:
                .cancelled
            case .timedOut:
                .timedOut
            case nil:
                nil
            }
        }
    }

    func runWatchdog(deadline: ContinuousClock.Instant) {
        var target: pid_t?
        condition.lock()
        while !cleanupFinished, !cleanupClaimed {
            if stopReason == nil, ContinuousClock().now >= deadline {
                stopReason = .timedOut
            }
            if stopReason != nil, let processID {
                cleanupClaimed = true
                target = processID
                break
            }
            let remaining = ContinuousClock().now.duration(to: deadline)
            let interval = Self.waitInterval(for: remaining)
            _ = condition.wait(until: Date().addingTimeInterval(interval))
        }
        condition.unlock()

        guard let target else { return }
        performClaimedCleanup(processID: target)
    }

    private static func waitInterval(for remaining: Duration) -> TimeInterval {
        guard remaining > .zero else { return 0 }
        let components = remaining.components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        return min(max(seconds, 0.001), 0.050)
    }
}

extension CodexSuspendedProcessIdentityRunner {
    static func startWatchdog(
        state: CodexSuspendedProcessLifecycleState,
        deadline: ContinuousClock.Instant
    ) -> DispatchGroup {
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            state.runWatchdog(deadline: deadline)
            group.leave()
        }
        return group
    }

    static func killAndReap(
        processID: pid_t,
        state: CodexSuspendedProcessLifecycleState
    ) throws {
        if let target = state.claimCleanup() {
            guard target == processID else {
                throw CodexSuspendedProcessIdentityInspectionError.processIdentityMismatch
            }
            state.performClaimedCleanup(processID: target)
        }
        try state.waitForCleanup()
    }
}
