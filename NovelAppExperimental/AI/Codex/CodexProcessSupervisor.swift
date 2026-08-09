import Darwin
import Foundation

#if !FUMINIWA_ENABLE_EXPERIMENTAL_AI
#error("Codex process supervision must only compile in FUMINIWAExperimental")
#endif

struct CodexProcessInvocation: Sendable, Equatable {
    static let maximumStandardInputBytes = 512 * 1024
    static let maximumStandardOutputBytes = 512 * 1024
    static let maximumStandardErrorBytes = 16 * 1024
    static let maximumTimeout: Duration = .seconds(120)
    static let maximumTerminationGracePeriod: Duration = .seconds(10)

    let executablePath: String
    let workingDirectoryPath: String
    let arguments: [String]
    let environment: [String: String]
    let standardInput: Data
    let timeout: Duration
    let terminationGracePeriod: Duration

    init(
        executablePath: String,
        workingDirectoryPath: String,
        arguments: [String],
        environment: [String: String],
        standardInput: Data,
        timeout: Duration,
        terminationGracePeriod: Duration
    ) throws {
        self.executablePath = executablePath
        self.workingDirectoryPath = workingDirectoryPath
        self.arguments = arguments
        self.environment = environment
        self.standardInput = standardInput
        self.timeout = timeout
        self.terminationGracePeriod = terminationGracePeriod
        try validate()
    }

    func validate() throws {
        try Self.validateCanonicalPath(executablePath, kind: .executable)
        try Self.validateCanonicalPath(workingDirectoryPath, kind: .workingDirectory)
        guard timeout > .zero, timeout <= Self.maximumTimeout else {
            throw CodexProcessSupervisorError.invalidTimeout
        }
        let validGracePeriod = terminationGracePeriod > .zero
            && terminationGracePeriod <= Self.maximumTerminationGracePeriod
        guard validGracePeriod else {
            throw CodexProcessSupervisorError.invalidTerminationGracePeriod
        }
        guard standardInput.count <= Self.maximumStandardInputBytes else {
            throw CodexProcessSupervisorError.standardInputLimitExceeded(
                limit: Self.maximumStandardInputBytes,
                actual: standardInput.count
            )
        }
        guard arguments.allSatisfy({ !$0.utf8.contains(0) }) else {
            throw CodexProcessSupervisorError.invalidArgument
        }
        for (key, value) in environment {
            let validKey = !key.isEmpty && !key.contains("=") && !key.utf8.contains(0)
            guard validKey, !value.utf8.contains(0) else {
                throw CodexProcessSupervisorError.invalidEnvironment
            }
        }
    }

    private enum PathKind {
        case executable
        case workingDirectory
    }

    private static func validateCanonicalPath(_ path: String, kind: PathKind) throws {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw kind == .executable
                ? CodexProcessSupervisorError.invalidExecutablePath
                : CodexProcessSupervisorError.invalidWorkingDirectoryPath
        }
        let url = URL(fileURLWithPath: path)
        let canonicalPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard canonicalPath == path else {
            throw kind == .executable
                ? CodexProcessSupervisorError.invalidExecutablePath
                : CodexProcessSupervisorError.invalidWorkingDirectoryPath
        }

        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            throw kind == .executable
                ? CodexProcessSupervisorError.invalidExecutablePath
                : CodexProcessSupervisorError.invalidWorkingDirectoryPath
        }
        let fileType = metadata.st_mode & S_IFMT
        switch kind {
        case .executable:
            let prohibitedMode = mode_t(S_ISUID | S_ISGID | S_IWGRP | S_IWOTH)
            let isSafeExecutable = fileType == S_IFREG
                && metadata.st_mode & prohibitedMode == 0
                && access(path, X_OK) == 0
            guard isSafeExecutable else {
                throw CodexProcessSupervisorError.invalidExecutablePath
            }
        case .workingDirectory:
            guard fileType == S_IFDIR else {
                throw CodexProcessSupervisorError.invalidWorkingDirectoryPath
            }
        }
    }
}

struct CodexProcessResult: Sendable, Equatable {
    enum Termination: Sendable, Equatable {
        case exited(code: Int32)
        case signaled(signal: Int32)
    }

    let standardOutput: Data
    let standardErrorByteCount: Int
    let termination: Termination
}

enum CodexProcessSupervisorError: Error, Sendable, Equatable {
    case alreadyRunning
    case invalidExecutablePath
    case invalidWorkingDirectoryPath
    case invalidArgument
    case invalidEnvironment
    case invalidTimeout
    case invalidTerminationGracePeriod
    case standardInputLimitExceeded(limit: Int, actual: Int)
    case pipe2Unavailable
    case unsafePipeDescriptor
    case systemCallFailed(operation: String, code: Int32)
    case cancelled
    case timedOut
    case standardOutputLimitExceeded(limit: Int, actualAtLeast: Int)
    case standardErrorLimitExceeded(limit: Int, actualAtLeast: Int)
    case inputWriteFailed(code: Int32)
    case processGroupNotEmpty(code: Int32)
    case processGroupSignalFailed(signal: Int32, code: Int32)
    case lingeringDescendant
    case processExitTimedOut
    case ioDrainTimedOut
    case ioWorkersFailedToStop
    case invalidWaitStatus
}

actor CodexProcessSupervisor {
    private var currentSession: CodexProcessSession?

    func run(_ invocation: CodexProcessInvocation) async throws -> CodexProcessResult {
        guard currentSession == nil else {
            throw CodexProcessSupervisorError.alreadyRunning
        }
        try invocation.validate()
        let session = CodexProcessSession(invocation: invocation)
        currentSession = session
        defer {
            if currentSession === session {
                currentSession = nil
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                session.start(continuation: continuation)
            }
        } onCancel: {
            session.requestStop(.cancelled)
        }
    }

    func cancel() async {
        currentSession?.requestStop(.cancelled)
    }
}

final class CodexProcessSession: @unchecked Sendable {
    enum StopReason: Sendable, Equatable {
        case exited
        case cancelled
        case timedOut
        case failure(CodexProcessSupervisorError)
    }

    private let invocation: CodexProcessInvocation
    private let state = CodexProcessState()
    private let queue = DispatchQueue(
        label: "dev.serikayuzuki.fuminiwa.codex-process-supervisor",
        qos: .userInitiated
    )

    init(invocation: CodexProcessInvocation) {
        self.invocation = invocation
    }

    func start(
        continuation: CheckedContinuation<CodexProcessResult, any Error>
    ) {
        queue.async { [self] in
            do {
                try continuation.resume(returning: CodexProcessRunner.run(invocation, state: state))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func requestStop(_ reason: StopReason) {
        state.requestStop(reason)
    }
}

struct CodexProcessStateSnapshot: Sendable {
    let stopReason: CodexProcessSession.StopReason?
    let processID: pid_t?
    let isReaped: Bool
    let directChildOwnershipLost: Bool
}

final class CodexProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var stopReason: CodexProcessSession.StopReason?
    private var processID: pid_t?
    private var reaped = false
    private var directChildOwnershipLost = false
    private var ioShouldStop = false

    func requestStop(_ reason: CodexProcessSession.StopReason) {
        lock.withLock {
            if stopReason == nil {
                stopReason = reason
            }
        }
    }

    func install(processID: pid_t) {
        lock.withLock {
            self.processID = processID
        }
    }

    func markReaped() {
        lock.withLock {
            reaped = true
        }
    }

    func markDirectChildOwnershipLost() {
        lock.withLock {
            directChildOwnershipLost = true
        }
    }

    func stopIO() {
        lock.withLock {
            ioShouldStop = true
        }
    }

    func shouldStopIO() -> Bool {
        lock.withLock { ioShouldStop }
    }

    func stopReason(
        claimingTimeoutAt deadline: ContinuousClock.Instant
    ) -> CodexProcessSession.StopReason? {
        lock.withLock {
            if stopReason == nil, ContinuousClock().now >= deadline {
                stopReason = .timedOut
            }
            return stopReason
        }
    }

    func shouldStopInput(
        deadline: ContinuousClock.Instant
    ) -> Bool {
        lock.withLock {
            if stopReason == nil, ContinuousClock().now >= deadline {
                stopReason = .timedOut
            }
            return switch stopReason {
            case .cancelled, .timedOut, .failure:
                true
            case .exited, nil:
                ioShouldStop
            }
        }
    }

    func snapshot() -> CodexProcessStateSnapshot {
        lock.withLock {
            CodexProcessStateSnapshot(
                stopReason: stopReason,
                processID: processID,
                isReaped: reaped,
                directChildOwnershipLost: directChildOwnershipLost
            )
        }
    }
}

enum CodexProcessRunner {}
