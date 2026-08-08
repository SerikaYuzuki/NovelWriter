import Darwin
import Foundation

#if !FUMINIWA_ENABLE_EXPERIMENTAL_AI
#error("Codex process supervision must only compile in FUMINIWAExperimental")
#endif

struct CodexProcessPipes {
    private(set) var stdinRead: Int32 = -1
    private(set) var stdinWrite: Int32 = -1
    private(set) var stdoutRead: Int32 = -1
    private(set) var stdoutWrite: Int32 = -1
    private(set) var stderrRead: Int32 = -1
    private(set) var stderrWrite: Int32 = -1

    init() throws {
        do {
            (stdinRead, stdinWrite) = try CodexProcessRunner.makePipe2()
            (stdoutRead, stdoutWrite) = try CodexProcessRunner.makePipe2()
            (stderrRead, stderrWrite) = try CodexProcessRunner.makePipe2()
        } catch {
            closeAll()
            throw error
        }
    }

    mutating func configureParentEnds() throws {
        try CodexProcessRunner.configureParentDescriptor(
            stdinWrite,
            noSignalOnPipe: true
        )
        try CodexProcessRunner.configureParentDescriptor(
            stdoutRead,
            noSignalOnPipe: false
        )
        try CodexProcessRunner.configureParentDescriptor(
            stderrRead,
            noSignalOnPipe: false
        )
    }

    mutating func transferParentEndsToIO(
        input: Data,
        deadline: ContinuousClock.Instant,
        state: CodexProcessState
    ) -> CodexProcessIO {
        CodexProcessRunner.closeDescriptor(&stdinRead)
        CodexProcessRunner.closeDescriptor(&stdoutWrite)
        CodexProcessRunner.closeDescriptor(&stderrWrite)
        let processIO = CodexProcessIO(
            stdinDescriptor: stdinWrite,
            stdoutDescriptor: stdoutRead,
            stderrDescriptor: stderrRead,
            input: input,
            deadline: deadline,
            state: state
        )
        stdinWrite = -1
        stdoutRead = -1
        stderrRead = -1
        return processIO
    }

    mutating func closeAll() {
        CodexProcessRunner.closeDescriptor(&stdinRead)
        CodexProcessRunner.closeDescriptor(&stdinWrite)
        CodexProcessRunner.closeDescriptor(&stdoutRead)
        CodexProcessRunner.closeDescriptor(&stdoutWrite)
        CodexProcessRunner.closeDescriptor(&stderrRead)
        CodexProcessRunner.closeDescriptor(&stderrWrite)
    }

    var allDescriptors: [Int32] {
        [stdinRead, stdinWrite, stdoutRead, stdoutWrite, stderrRead, stderrWrite]
    }
}

extension CodexProcessRunner {
    static func makePipe2() throws -> (Int32, Int32) {
        typealias Pipe2Function = @convention(c) (
            UnsafeMutablePointer<Int32>,
            Int32
        ) -> Int32
        guard let handle = dlopen(nil, RTLD_NOW) else {
            throw CodexProcessSupervisorError.pipe2Unavailable
        }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "pipe2") else {
            throw CodexProcessSupervisorError.pipe2Unavailable
        }
        let function = unsafeBitCast(symbol, to: Pipe2Function.self)
        var descriptors = [Int32](repeating: -1, count: 2)
        let result = descriptors.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return Int32(-1) }
            return function(baseAddress, O_CLOEXEC)
        }
        guard result == 0 else {
            throw CodexProcessSupervisorError.systemCallFailed(
                operation: "pipe2",
                code: errno
            )
        }
        guard descriptors.allSatisfy({ $0 > STDERR_FILENO }) else {
            for descriptor in descriptors where descriptor >= 0 {
                _ = close(descriptor)
            }
            throw CodexProcessSupervisorError.unsafePipeDescriptor
        }
        return (descriptors[0], descriptors[1])
    }

    static func configureParentDescriptor(
        _ descriptor: Int32,
        noSignalOnPipe: Bool
    ) throws {
        if noSignalOnPipe, fcntl(descriptor, F_SETNOSIGPIPE, 1) == -1 {
            throw CodexProcessSupervisorError.systemCallFailed(
                operation: "fcntl(F_SETNOSIGPIPE)",
                code: errno
            )
        }
        let flags = fcntl(descriptor, F_GETFL)
        let configuredNonblocking = flags != -1
            && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1
        guard configuredNonblocking else {
            throw CodexProcessSupervisorError.systemCallFailed(
                operation: "fcntl(O_NONBLOCK)",
                code: errno
            )
        }
    }

    static func spawn(
        _ invocation: CodexProcessInvocation,
        pipes: CodexProcessPipes
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try checkSpawnCall(posix_spawn_file_actions_init(&actions), "file_actions_init")
        defer { posix_spawn_file_actions_destroy(&actions) }
        try checkSpawnCall(posix_spawnattr_init(&attributes), "spawnattr_init")
        defer { posix_spawnattr_destroy(&attributes) }

        try configureFileActions(&actions, invocation: invocation, pipes: pipes)
        try configureSpawnAttributes(&attributes)

        let argv = [invocation.executablePath] + invocation.arguments
        let environment = invocation.environment
            .sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
            .map { "\($0.key)=\($0.value)" }
        var processID = pid_t()
        let result = try withCStringVector(argv) { argvPointer in
            try withCStringVector(environment) { environmentPointer in
                posix_spawn(
                    &processID,
                    invocation.executablePath,
                    &actions,
                    &attributes,
                    argvPointer,
                    environmentPointer
                )
            }
        }
        try checkSpawnCall(result, "posix_spawn")
        do {
            try verifySpawnedProcessGroup(processID)
        } catch {
            if let cleanupError = cleanupUnverifiedDirectChild(processID) {
                throw cleanupError
            }
            throw error
        }
        return processID
    }

    private static func configureFileActions(
        _ actions: inout posix_spawn_file_actions_t?,
        invocation: CodexProcessInvocation,
        pipes: CodexProcessPipes
    ) throws {
        try checkSpawnCall(
            posix_spawn_file_actions_addchdir_np(
                &actions,
                invocation.workingDirectoryPath
            ),
            "file_actions_addchdir"
        )
        let mappings = [
            (pipes.stdinRead, STDIN_FILENO),
            (pipes.stdoutWrite, STDOUT_FILENO),
            (pipes.stderrWrite, STDERR_FILENO)
        ]
        for (source, destination) in mappings {
            try checkSpawnCall(
                posix_spawn_file_actions_adddup2(&actions, source, destination),
                "file_actions_adddup2"
            )
        }
        for descriptor in pipes.allDescriptors {
            try checkSpawnCall(
                posix_spawn_file_actions_addclose(&actions, descriptor),
                "file_actions_addclose"
            )
        }
    }

    private static func configureSpawnAttributes(
        _ attributes: inout posix_spawnattr_t?
    ) throws {
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        sigdelset(&defaultSignals, SIGKILL)
        sigdelset(&defaultSignals, SIGSTOP)
        try checkSpawnCall(
            posix_spawnattr_setsigmask(&attributes, &emptyMask),
            "spawnattr_setsigmask"
        )
        try checkSpawnCall(
            posix_spawnattr_setsigdefault(&attributes, &defaultSignals),
            "spawnattr_setsigdefault"
        )
        try checkSpawnCall(
            posix_spawnattr_setpgroup(&attributes, 0),
            "spawnattr_setpgroup"
        )
        let flags = Int16(
            POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETPGROUP
                | POSIX_SPAWN_SETSIGMASK
                | POSIX_SPAWN_SETSIGDEF
        )
        try checkSpawnCall(
            posix_spawnattr_setflags(&attributes, flags),
            "spawnattr_setflags"
        )
    }

    private static func withCStringVector<T>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> T
    ) throws -> T {
        var pointers = strings.map { strdup($0) }
        guard pointers.allSatisfy({ $0 != nil }) else {
            for pointer in pointers {
                free(pointer)
            }
            throw CodexProcessSupervisorError.systemCallFailed(
                operation: "strdup",
                code: ENOMEM
            )
        }
        pointers.append(nil)
        defer { for pointer in pointers {
            free(pointer)
        } }
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw CodexProcessSupervisorError.systemCallFailed(
                    operation: "CString vector",
                    code: EINVAL
                )
            }
            return try body(baseAddress)
        }
    }

    private static func checkSpawnCall(
        _ result: Int32,
        _ operation: String
    ) throws {
        guard result == 0 else {
            throw CodexProcessSupervisorError.systemCallFailed(
                operation: operation,
                code: result
            )
        }
    }

    private static func verifySpawnedProcessGroup(_ processID: pid_t) throws {
        errno = 0
        let processGroupID = getpgid(processID)
        guard processGroupID == processID else {
            throw CodexProcessSupervisorError.systemCallFailed(
                operation: "getpgid",
                code: processGroupID == -1 ? errno : EPERM
            )
        }
    }

    private static func cleanupUnverifiedDirectChild(
        _ processID: pid_t
    ) -> CodexProcessSupervisorError? {
        var signalError: CodexProcessSupervisorError?
        errno = 0
        if kill(processID, SIGKILL) == -1, errno != ESRCH {
            signalError = .systemCallFailed(
                operation: "kill(unverified child)",
                code: errno
            )
        }
        let deadline = ContinuousClock().now.advanced(by: .seconds(1))
        var status: Int32 = 0
        repeat {
            errno = 0
            let result = waitpid(processID, &status, WNOHANG)
            if result == processID {
                return nil
            }
            if result == -1, errno != EINTR {
                return .systemCallFailed(
                    operation: "waitpid(unverified child)",
                    code: errno
                )
            }
            sleepBriefly()
        } while ContinuousClock().now < deadline
        return signalError ?? .processExitTimedOut
    }

    static func closeDescriptor(_ descriptor: inout Int32) {
        guard descriptor >= 0 else { return }
        _ = close(descriptor)
        descriptor = -1
    }
}
