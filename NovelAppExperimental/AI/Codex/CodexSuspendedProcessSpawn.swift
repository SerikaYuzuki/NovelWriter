import Darwin
import Foundation

#if !FUMINIWA_ENABLE_EXPERIMENTAL_AI
#error("Codex suspended-process inspection must only compile in FUMINIWAExperimental")
#endif

enum CodexSuspendedProcessSpawner {
    private static let emptyWorkingDirectory = "/private/var/empty"
    private static let nullDevice = "/dev/null"

    static func spawn(
        absolutePath: String,
        architecture: CodexRuntimeArchitecture
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try check(posix_spawn_file_actions_init(&actions), "file_actions_init")
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes), "spawnattr_init")
        defer { posix_spawnattr_destroy(&attributes) }

        try configureFileActions(&actions)
        try configureAttributes(&attributes, architecture: architecture)

        guard let argument = strdup(absolutePath) else {
            throw CodexSuspendedProcessIdentityInspectionError.systemCallFailed(
                operation: "strdup(argv0)",
                code: ENOMEM
            )
        }
        defer { free(argument) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [argument, nil]
        var emptyEnvironment: [UnsafeMutablePointer<CChar>?] = [nil]
        var processID = pid_t()
        let result = arguments.withUnsafeMutableBufferPointer { argumentBuffer in
            emptyEnvironment.withUnsafeMutableBufferPointer { environmentBuffer in
                posix_spawn(
                    &processID,
                    absolutePath,
                    &actions,
                    &attributes,
                    argumentBuffer.baseAddress,
                    environmentBuffer.baseAddress
                )
            }
        }
        try check(result, "posix_spawn(suspended)")
        return processID
    }

    private static func configureFileActions(
        _ actions: inout posix_spawn_file_actions_t?
    ) throws {
        try check(
            posix_spawn_file_actions_addchdir_np(
                &actions,
                emptyWorkingDirectory
            ),
            "file_actions_addchdir"
        )
        try check(
            posix_spawn_file_actions_addopen(
                &actions,
                STDIN_FILENO,
                nullDevice,
                O_RDONLY,
                0
            ),
            "file_actions_addopen(stdin)"
        )
        for descriptor in [STDOUT_FILENO, STDERR_FILENO] {
            try check(
                posix_spawn_file_actions_addopen(
                    &actions,
                    descriptor,
                    nullDevice,
                    O_WRONLY,
                    0
                ),
                "file_actions_addopen(output)"
            )
        }
    }

    private static func configureAttributes(
        _ attributes: inout posix_spawnattr_t?,
        architecture: CodexRuntimeArchitecture
    ) throws {
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        sigdelset(&defaultSignals, SIGKILL)
        sigdelset(&defaultSignals, SIGSTOP)
        try check(
            posix_spawnattr_setsigmask(&attributes, &emptyMask),
            "spawnattr_setsigmask"
        )
        try check(
            posix_spawnattr_setsigdefault(&attributes, &defaultSignals),
            "spawnattr_setsigdefault"
        )
        try check(
            posix_spawnattr_setpgroup(&attributes, 0),
            "spawnattr_setpgroup"
        )

        var preferredCPUType = [cpuType(for: architecture)]
        var preferenceCount = 0
        let preferenceResult = preferredCPUType.withUnsafeMutableBufferPointer { buffer in
            posix_spawnattr_setbinpref_np(
                &attributes,
                buffer.count,
                buffer.baseAddress,
                &preferenceCount
            )
        }
        try check(preferenceResult, "spawnattr_setbinpref")
        guard preferenceCount == 1 else {
            throw CodexSuspendedProcessIdentityInspectionError.systemCallFailed(
                operation: "spawnattr_setbinpref(count)",
                code: EINVAL
            )
        }

        let flags = Int16(
            POSIX_SPAWN_START_SUSPENDED
                | POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETPGROUP
                | POSIX_SPAWN_SETSIGMASK
                | POSIX_SPAWN_SETSIGDEF
        )
        try check(
            posix_spawnattr_setflags(&attributes, flags),
            "spawnattr_setflags"
        )
    }

    private static func cpuType(
        for architecture: CodexRuntimeArchitecture
    ) -> cpu_type_t {
        switch architecture {
        case .arm64:
            CPU_TYPE_ARM64
        case .x64:
            CPU_TYPE_X86_64
        }
    }

    private static func check(_ result: Int32, _ operation: String) throws {
        guard result == 0 else {
            throw CodexSuspendedProcessIdentityInspectionError.systemCallFailed(
                operation: operation,
                code: result
            )
        }
    }
}
