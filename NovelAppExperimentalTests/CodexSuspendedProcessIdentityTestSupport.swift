import Darwin
import Foundation
@testable import FUMINIWAExperimental
import Testing

// swiftlint:disable file_length

struct SyntheticSuspendedProcessHelper: Sendable {
    let root: URL
    let executable: URL
    let initializerMarker: URL
    let mainMarker: URL

    func remove() {
        removeSuspendedProcessTestFixture(at: root)
    }
}

struct SystemSuspendedProcessFixture: Sendable {
    let absolutePath: String
    let expectedIdentity: CodexSuspendedProcessExpectedIdentity
}

struct SuspendedProcessPathSwapFixture: Sendable {
    let original: SyntheticSuspendedProcessHelper
    let replacement: SyntheticSuspendedProcessHelper
    let displacedPath: URL
    let replacementAfterSpawnPath: URL
    let expectedIdentity: CodexSuspendedProcessExpectedIdentity

    var launchPath: URL {
        original.executable
    }

    var replacementPath: URL {
        replacement.executable
    }

    func installReplacement() {
        let displaced = rename(launchPath.path, displacedPath.path) == 0
        let installed = displaced
            && rename(replacementPath.path, launchPath.path) == 0
        guard installed else {
            Issue.record("failed to install suspended-process replacement")
            return
        }
    }

    func restoreOriginalPath() {
        let displacedReplacement = rename(
            launchPath.path,
            replacementAfterSpawnPath.path
        ) == 0
        let restored = displacedReplacement
            && rename(displacedPath.path, launchPath.path) == 0
        guard restored else {
            Issue.record("failed to restore suspended-process launch path")
            return
        }
    }

    func remove() {
        original.remove()
        replacement.remove()
    }

    func expectUserCodeDidNotRun() {
        expectSyntheticUserCodeDidNotRun(original)
        expectSyntheticUserCodeDidNotRun(replacement)
    }
}

func systemSuspendedProcessFixture(
    absolutePath: String = "/usr/bin/true",
    architecture: CodexRuntimeArchitecture = suspendedTestArchitecture
) throws -> SystemSuspendedProcessFixture {
    let physicalURL = try URL(
        fileURLWithPath: physicalPath(for: URL(fileURLWithPath: absolutePath)),
        isDirectory: false
    )
    let signature = CodexNodeCodeSignatureInspector.observe(
        absolutePath: physicalURL.path,
        requestedArchitecture: architecture
    )
    guard signature.validity == .valid, let cdHash = signature.cdHash else {
        throw SuspendedProcessTestError.systemFixtureSignatureUnavailable
    }
    return try SystemSuspendedProcessFixture(
        absolutePath: physicalURL.path,
        expectedIdentity: CodexSuspendedProcessExpectedIdentity(
            architecture: architecture,
            cdHash: cdHash
        )
    )
}

func suspendedProcessRequest(
    fixture: SystemSuspendedProcessFixture,
    timeout: Duration = .seconds(2)
) throws -> CodexSuspendedProcessIdentityRequest {
    try CodexSuspendedProcessIdentityRequest(
        absolutePath: fixture.absolutePath,
        expectedIdentity: fixture.expectedIdentity,
        timeout: timeout
    )
}

func makeSuspendedProcessPathSwapFixture() async throws -> SuspendedProcessPathSwapFixture {
    let original = try await makeSyntheticSuspendedProcessHelper(variant: 0x41)
    var replacement: SyntheticSuspendedProcessHelper?
    do {
        let createdReplacement = try await makeSyntheticSuspendedProcessHelper(variant: 0x42)
        replacement = createdReplacement
        let signature = CodexNodeCodeSignatureInspector.observe(
            absolutePath: original.executable.path,
            requestedArchitecture: suspendedTestArchitecture
        )
        let cdHash = try #require(signature.cdHash)
        return try SuspendedProcessPathSwapFixture(
            original: original,
            replacement: createdReplacement,
            displacedPath: original.root.appending(path: "displaced-helper"),
            replacementAfterSpawnPath: createdReplacement.root.appending(
                path: "spawned-replacement"
            ),
            expectedIdentity: CodexSuspendedProcessExpectedIdentity(
                architecture: suspendedTestArchitecture,
                cdHash: cdHash
            )
        )
    } catch {
        original.remove()
        replacement?.remove()
        throw error
    }
}

func capturedSuspendedProcessError(
    _ operation: () async throws -> Void
) async -> CodexSuspendedProcessIdentityInspectionError? {
    do {
        try await operation()
        Issue.record("expected CodexSuspendedProcessIdentityInspectionError")
        return nil
    } catch let error as CodexSuspendedProcessIdentityInspectionError {
        return error
    } catch {
        Issue.record("unexpected error: \(error)")
        return nil
    }
}

func makeSyntheticSuspendedProcessHelper(
    variant: UInt8 = 0x41
) async throws -> SyntheticSuspendedProcessHelper {
    let root = try makeNodeInspectorTemporaryRoot()
    var removeRootOnFailure = true
    defer {
        if removeRootOnFailure {
            removeSuspendedProcessTestFixture(at: root)
        }
    }
    let source = root.appending(path: "helper.c")
    let executable = root.appending(path: "synthetic-helper")
    let initializerMarker = root.appending(path: "initializer-marker")
    let mainMarker = root.appending(path: "main-marker")
    let sourceBytes = Data(syntheticSuspendedProcessSource(
        variant: variant,
        initializerMarkerPath: initializerMarker.path,
        mainMarkerPath: mainMarker.path
    ).utf8)
    try sourceBytes.write(to: source, options: .withoutOverwriting)

    let compilerResult = try await CodexProcessSupervisor().run(
        syntheticHelperCompilerInvocation(
            root: root,
            source: source,
            executable: executable
        )
    )
    guard compilerResult.termination == .exited(code: 0) else {
        throw SuspendedProcessTestError.helperCompilationFailed
    }
    guard chmod(executable.path, 0o700) == 0 else {
        throw SuspendedProcessTestError.systemCallFailed
    }

    let helper = SyntheticSuspendedProcessHelper(
        root: root,
        executable: executable,
        initializerMarker: initializerMarker,
        mainMarker: mainMarker
    )
    removeRootOnFailure = false
    return helper
}

func removeSuspendedProcessTestFixture(at root: URL) {
    guard FileManager.default.fileExists(atPath: root.path) else { return }
    do {
        try FileManager.default.removeItem(at: root)
    } catch {
        Issue.record("failed to remove suspended-process fixture: \(error)")
    }
}

private func syntheticHelperCompilerInvocation(
    root: URL,
    source: URL,
    executable: URL
) throws -> CodexProcessInvocation {
    try CodexProcessInvocation(
        executablePath: "/usr/bin/xcrun",
        workingDirectoryPath: "/var/empty",
        arguments: [
            "clang",
            "-arch",
            suspendedHelperArchitectureName,
            "-Os",
            "-Wl,-dead_strip",
            "-o",
            executable.path,
            source.path
        ],
        environment: ["TMPDIR": root.path],
        standardInput: Data(),
        timeout: .seconds(10),
        terminationGracePeriod: .milliseconds(100)
    )
}

func expectSyntheticUserCodeDidNotRun(
    _ fixture: SyntheticSuspendedProcessHelper
) {
    #expect(!FileManager.default.fileExists(atPath: fixture.initializerMarker.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.mainMarker.path))
}

final class SuspendedProcessPIDCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var processID: pid_t?

    func record(_ processID: pid_t) {
        lock.withLock {
            if self.processID == nil {
                self.processID = processID
            }
        }
    }

    func value() -> pid_t? {
        lock.withLock { processID }
    }

    func recordStoppedDirectChild(
        executablePath: String,
        architecture: CodexRuntimeArchitecture = suspendedTestArchitecture
    ) {
        guard let processID = stoppedDirectChildPID(executablePath: executablePath) else {
            Issue.record("suspended direct child was not observable")
            return
        }
        expectStoppedDirectChildKernelIdentity(
            processID,
            executablePath: executablePath,
            architecture: architecture
        )
        record(processID)
    }
}

func expectSuspendedProcessWasKilledAndReaped(
    _ processID: pid_t?
) async throws {
    guard let processID else {
        Issue.record("suspended direct child PID is unavailable")
        return
    }
    try await expectProcessGone(processID)
    expectDirectChildAlreadyReaped(processID)
}

final class SuspendedProcessHookCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock { count += 1 }
    }

    func value() -> Int {
        lock.withLock { count }
    }
}

final class SuspendedProcessHookGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func enterAndWait() {
        entered.signal()
        guard release.wait(timeout: .now() + 2) == .success else {
            Issue.record("suspended-process hook gate timed out")
            return
        }
    }

    func waitUntilEntered() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [entered] in
                continuation.resume(returning: entered.wait(timeout: .now() + 1) == .success)
            }
        }
    }

    func open() {
        release.signal()
    }
}

struct SuspendedProcessCleanupWatchdog: Sendable {
    let task: Task<Void, Never>
    let state: SuspendedProcessCleanupWatchdogState

    func cancel() {
        let didFire = state.cancel()
        task.cancel()
        if didFire {
            Issue.record("suspended-process cleanup required the test watchdog")
        }
    }
}

final class SuspendedProcessCleanupWatchdogState: @unchecked Sendable {
    private enum Status {
        case armed
        case cancelled
        case fired
    }

    private let lock = NSLock()
    private var status = Status.armed

    func cancel() -> Bool {
        lock.withLock {
            switch status {
            case .armed:
                status = .cancelled
                return false
            case .cancelled:
                return false
            case .fired:
                return true
            }
        }
    }

    func claimFire() -> Bool {
        lock.withLock {
            guard status == .armed else { return false }
            status = .fired
            return true
        }
    }
}

func suspendedProcessCleanupWatchdog(
    executablePath: String
) -> SuspendedProcessCleanupWatchdog {
    let state = SuspendedProcessCleanupWatchdogState()
    let task = Task {
        do {
            try await Task.sleep(for: .seconds(8))
        } catch {
            return
        }
        guard state.claimFire() else { return }
        guard let processID = stoppedDirectChildPID(executablePath: executablePath) else {
            return
        }
        SupervisorProcessIdentity.capture(processID: processID)?.terminateIfStillMatching()
    }
    return SuspendedProcessCleanupWatchdog(task: task, state: state)
}

private func stoppedDirectChildPID(executablePath: String) -> pid_t? {
    for _ in 0 ..< 50 {
        if let processID = currentDirectChildPIDs().first(where: {
            processPath($0) == executablePath && processIsStopped($0)
        }) {
            return processID
        }
        usleep(1000)
    }
    return nil
}

private func currentDirectChildPIDs() -> [pid_t] {
    var processIDs = [pid_t](repeating: 0, count: 128)
    let byteCapacity = processIDs.count * MemoryLayout<pid_t>.stride
    let processCount = processIDs.withUnsafeMutableBytes { bytes in
        proc_listchildpids(getpid(), bytes.baseAddress, Int32(byteCapacity))
    }
    guard processCount > 0 else { return [] }
    let count = min(Int(processCount), processIDs.count)
    return Array(processIDs.prefix(count)).filter { $0 > 1 }
}

private func processPath(_ processID: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) * 4)
    let byteCount = proc_pidpath(processID, &buffer, UInt32(buffer.count))
    guard byteCount > 0 else { return nil }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(bytes: bytes, encoding: .utf8)
}

private func processIsStopped(_ processID: pid_t) -> Bool {
    var info = proc_bsdinfo()
    let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
    let actualSize = withUnsafeMutablePointer(to: &info) {
        proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, $0, expectedSize)
    }
    return actualSize == expectedSize && Int32(info.pbi_status) == SSTOP
}

private func expectStoppedDirectChildKernelIdentity(
    _ processID: pid_t,
    executablePath: String,
    architecture: CodexRuntimeArchitecture
) {
    var info = proc_bsdinfo()
    let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
    let infoResult = withUnsafeMutablePointer(to: &info) {
        proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, $0, infoSize)
    }
    #expect(infoResult == infoSize)
    guard infoResult == infoSize else { return }

    #expect(info.pbi_pid == UInt32(processID))
    #expect(info.pbi_ppid == UInt32(getpid()))
    #expect(info.pbi_pgid == UInt32(processID))
    #expect(info.pbi_uid == geteuid())
    #expect(info.pbi_ruid == getuid())
    #expect(info.pbi_gid == getegid())
    #expect(info.pbi_rgid == getgid())
    #expect(Int32(info.pbi_status) == SSTOP)
    #expect(info.pbi_start_tvsec > 0)
    #expect(getpgid(processID) == processID)
    #expect(processPath(processID) == executablePath)

    var processArchitecture = proc_archinfo()
    let architectureSize = Int32(MemoryLayout<proc_archinfo>.size)
    let architectureResult = withUnsafeMutablePointer(to: &processArchitecture) {
        proc_pidinfo(processID, PROC_PIDARCHINFO, 0, $0, architectureSize)
    }
    #expect(architectureResult == architectureSize)
    guard architectureResult == architectureSize else { return }
    let expectedCPUType: cpu_type_t = switch architecture {
    case .arm64:
        CPU_TYPE_ARM64
    case .x64:
        CPU_TYPE_X86_64
    }
    #expect(processArchitecture.p_cputype == expectedCPUType)
}

private var suspendedHelperArchitectureName: String {
    #if arch(arm64)
    "arm64"
    #elseif arch(x86_64)
    "x86_64"
    #else
    #error("Unsupported test architecture")
    #endif
}

var suspendedTestArchitecture: CodexRuntimeArchitecture {
    #if arch(arm64)
    .arm64
    #elseif arch(x86_64)
    .x64
    #else
    #error("Unsupported test architecture")
    #endif
}

private func syntheticSuspendedProcessSource(
    variant: UInt8,
    initializerMarkerPath: String,
    mainMarkerPath: String
) -> String {
    """
    #include <fcntl.h>
    #include <unistd.h>

    static const unsigned char synthetic_variant = \(variant);
    static const char initializer_marker[] = {
        \(syntheticCStringBytes(initializerMarkerPath))
    };
    static const char main_marker[] = {
        \(syntheticCStringBytes(mainMarkerPath))
    };

    static void write_marker(const char *path) {
        int descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (descriptor < 0) _exit(92);
        if (write(descriptor, &synthetic_variant, 1) != 1) _exit(93);
        if (close(descriptor) != 0) _exit(94);
    }

    __attribute__((constructor))
    static void synthetic_initializer(void) {
        write_marker(initializer_marker);
    }

    int main(void) {
        write_marker(main_marker);
        for (;;) pause();
    }
    """
}

private func syntheticCStringBytes(_ value: String) -> String {
    (Array(value.utf8) + [0]).map(String.init).joined(separator: ", ")
}

enum SuspendedProcessTestError: Error {
    case helperCompilationFailed
    case systemFixtureSignatureUnavailable
    case systemCallFailed
}
