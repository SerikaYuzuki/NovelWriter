import Darwin
import Foundation

#if !FUMINIWA_ENABLE_EXPERIMENTAL_AI
#error("Codex suspended-process inspection must only compile in FUMINIWAExperimental")
#endif

private enum CodexSuspendedInspectionOutcome {
    case success(CodexSuspendedProcessIdentityObservation)
    case failure(any Error)
}

private struct CodexSuspendedProbeContext {
    let request: CodexSuspendedProcessIdentityRequest
    let executable: CodexSuspendedProcessExecutableLease
    let processID: pid_t
    let state: CodexSuspendedProcessLifecycleState
    let watchdog: DispatchGroup
    let testingHooks: CodexSuspendedProcessIdentityInspectorTestingHooks
    let deadline: ContinuousClock.Instant
}

extension CodexSuspendedProcessIdentityRunner {
    static func inspect(
        _ request: CodexSuspendedProcessIdentityRequest,
        state: CodexSuspendedProcessLifecycleState,
        testingHooks: CodexSuspendedProcessIdentityInspectorTestingHooks
    ) throws -> CodexSuspendedProcessIdentityObservation {
        let deadline = ContinuousClock().now.advanced(by: request.timeout)
        let executable = try prepareExecutable(
            for: request,
            state: state,
            testingHooks: testingHooks,
            deadline: deadline
        )
        defer { executable.close() }

        let processID = try CodexSuspendedProcessSpawner.spawn(
            absolutePath: request.absolutePath,
            architecture: request.expectedIdentity.architecture
        )
        state.install(processID: processID)
        let watchdog = startWatchdog(state: state, deadline: deadline)
        testingHooks.afterSuspendedSpawn?()
        let context = CodexSuspendedProbeContext(
            request: request,
            executable: executable,
            processID: processID,
            state: state,
            watchdog: watchdog,
            testingHooks: testingHooks,
            deadline: deadline
        )

        let outcome = captureActualIdentity(context)
        return try finishProbe(outcome: outcome, context: context)
    }

    private static func prepareExecutable(
        for request: CodexSuspendedProcessIdentityRequest,
        state: CodexSuspendedProcessLifecycleState,
        testingHooks: CodexSuspendedProcessIdentityInspectorTestingHooks,
        deadline: ContinuousClock.Instant
    ) throws -> CodexSuspendedProcessExecutableLease {
        try state.requireInspectionAllowed(deadline: deadline)
        let executable = try CodexSuspendedProcessExecutablePreflight.inspect(
            absolutePath: request.absolutePath
        )
        testingHooks.afterPreflightInspection?()
        do {
            try state.requireInspectionAllowed(deadline: deadline)
            try CodexSuspendedProcessExecutablePreflight.requireStable(executable)
            testingHooks.beforeSuspendedSpawn?()
            try state.requireInspectionAllowed(deadline: deadline)
            return executable
        } catch {
            executable.close()
            throw error
        }
    }

    private static func captureActualIdentity(
        _ context: CodexSuspendedProbeContext
    ) -> CodexSuspendedInspectionOutcome {
        do {
            try context.state.requireInspectionAllowed(deadline: context.deadline)
            try CodexSuspendedProcessExecutablePreflight.requireStable(context.executable)
            context.testingHooks.beforeActualIdentityInspection?()
            try context.state.requireInspectionAllowed(deadline: context.deadline)

            let first = try CodexSuspendedProcessActualIdentityInspector.inspect(
                processID: context.processID,
                absolutePath: context.request.absolutePath,
                expectedIdentity: context.request.expectedIdentity,
                deadline: context.deadline,
                state: context.state
            )
            context.testingHooks.afterActualIdentityInspection?()
            try context.state.requireInspectionAllowed(deadline: context.deadline)
            try CodexSuspendedProcessExecutablePreflight.requireStable(context.executable)

            let second = try CodexSuspendedProcessActualIdentityInspector.inspect(
                processID: context.processID,
                absolutePath: context.request.absolutePath,
                expectedIdentity: context.request.expectedIdentity,
                deadline: context.deadline,
                state: context.state
            )
            let identityIsStable = first.architecture == second.architecture
                && first.cdHash == second.cdHash
            guard identityIsStable else {
                throw CodexSuspendedProcessIdentityInspectionError.processIdentityMismatch
            }
            try context.state.requireInspectionAllowed(deadline: context.deadline)
            try CodexSuspendedProcessExecutablePreflight.requireStable(context.executable)
            return .success(
                CodexSuspendedProcessIdentityObservation(
                    architecture: second.architecture,
                    cdHash: second.cdHash
                )
            )
        } catch {
            return .failure(error)
        }
    }

    private static func finishProbe(
        outcome: CodexSuspendedInspectionOutcome,
        context: CodexSuspendedProbeContext
    ) throws -> CodexSuspendedProcessIdentityObservation {
        context.testingHooks.beforeCleanup?()
        var finalOutcome = outcome
        var cleanupError: (any Error)?
        do {
            try CodexSuspendedProcessExecutablePreflight.requireStable(context.executable)
        } catch {
            if case .success = finalOutcome {
                finalOutcome = .failure(error)
            }
        }
        do {
            try context.state.requireInspectionAllowed(deadline: context.deadline)
        } catch {
            finalOutcome = .failure(error)
        }
        do {
            try killAndReap(processID: context.processID, state: context.state)
        } catch {
            cleanupError = error
        }
        context.watchdog.wait()
        if let cleanupError {
            throw cleanupError
        }
        if let terminalError = context.state.terminalError() {
            throw terminalError
        }
        switch finalOutcome {
        case let .success(observation):
            return observation
        case let .failure(error):
            throw error
        }
    }
}
