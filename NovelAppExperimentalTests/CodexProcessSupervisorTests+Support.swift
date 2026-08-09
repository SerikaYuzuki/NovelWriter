import Darwin
import Foundation
@testable import FUMINIWAExperimental
import Testing

func supervisorInvocation(
    executablePath: String = "/bin/sh",
    workingDirectory: URL,
    script: String? = nil,
    environment: [String: String] = [:],
    standardInput: Data = Data(),
    timeout: Duration = .seconds(3),
    terminationGracePeriod: Duration = .milliseconds(100)
) throws -> CodexProcessInvocation {
    try CodexProcessInvocation(
        executablePath: executablePath,
        workingDirectoryPath: workingDirectory.path,
        arguments: script.map { ["-c", $0] } ?? [],
        environment: environment,
        standardInput: standardInput,
        timeout: timeout,
        terminationGracePeriod: terminationGracePeriod
    )
}

func makeSupervisorTemporaryDirectory() throws -> URL {
    let baseURL = FileManager.default.temporaryDirectory
        .standardizedFileURL
        .resolvingSymlinksInPath()
    let url = baseURL.appending(
        path: "FUMINIWA-CodexProcessSupervisorTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}

func physicalPath(for url: URL) throws -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard realpath(url.path, &buffer) != nil else {
        throw SupervisorTestError.physicalPathUnavailable
    }
    let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    guard let path = String(bytes: bytes, encoding: .utf8) else {
        throw SupervisorTestError.physicalPathUnavailable
    }
    return path
}

func environmentLines(_ data: Data) -> [String: String] {
    (String(data: data, encoding: .utf8) ?? "")
        .split(separator: "\n")
        .reduce(into: [:]) { result, line in
            let components = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard components.count == 2 else { return }
            result[String(components[0])] = String(components[1])
        }
}

func capturedSupervisorError(
    _ operation: () async throws -> Void
) async -> CodexProcessSupervisorError? {
    do {
        try await operation()
        Issue.record("expected CodexProcessSupervisorError")
        return nil
    } catch let error as CodexProcessSupervisorError {
        return error
    } catch {
        Issue.record("unexpected error: \(error)")
        return nil
    }
}

func waitForRecordedPID(at url: URL) async throws -> pid_t {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while clock.now < deadline {
        if let pid = try? recordedPID(at: url) {
            return pid
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("process did not publish its PID")
    throw SupervisorTestError.pidWasNotPublished
}

func waitForRecordedPID(
    at url: URL,
    cancelling supervisor: CodexProcessSupervisor,
    task: Task<CodexProcessResult, any Error>
) async throws -> pid_t {
    do {
        return try await waitForRecordedPID(at: url)
    } catch {
        await supervisor.cancel()
        _ = try? await task.value
        throw error
    }
}

func recordedPID(at url: URL) throws -> pid_t {
    let contents = try String(contentsOf: url, encoding: .utf8)
    guard let pid = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else {
        throw SupervisorTestError.invalidPID
    }
    return pid
}

func expectProcessAndGroupGone(_ leaderPID: pid_t) async throws {
    try await expectProcessGone(leaderPID)

    errno = 0
    let groupProbe = kill(-leaderPID, 0)
    let groupErrno = errno
    #expect(groupProbe == -1)
    #expect(groupErrno == ESRCH)
}

func expectProcessGone(_ pid: pid_t) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while clock.now < deadline {
        errno = 0
        if kill(pid, 0) == -1, errno == ESRCH {
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("process \(pid) still exists after bounded cleanup")
}

func expectDirectChildAlreadyReaped(_ pid: pid_t) {
    var status: Int32 = 0
    errno = 0
    let result = waitpid(pid, &status, WNOHANG)
    let waitErrno = errno
    #expect(result == -1)
    #expect(waitErrno == ECHILD)
}

struct SupervisorProcessIdentity: Equatable, Sendable {
    let processID: pid_t
    let processGroupID: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64

    static func capture(processID: pid_t) -> Self? {
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let actualSize = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, $0, expectedSize)
        }
        guard actualSize == expectedSize else { return nil }
        return Self(
            processID: pid_t(info.pbi_pid),
            processGroupID: pid_t(info.pbi_pgid),
            startSeconds: UInt64(info.pbi_start_tvsec),
            startMicroseconds: UInt64(info.pbi_start_tvusec)
        )
    }

    func terminateIfStillMatching() {
        guard Self.capture(processID: processID) == self else { return }
        if processGroupID > 1 {
            _ = kill(-processGroupID, SIGKILL)
        }
        _ = kill(processID, SIGKILL)
    }
}

struct SupervisorCleanupWatchdog: Sendable {
    let task: Task<Void, Never>
    let state: SupervisorCleanupWatchdogState

    func cancel() {
        let didFire = state.cancel()
        task.cancel()
        if didFire {
            Issue.record("supervisor cleanup required the test watchdog")
        }
    }
}

final class SupervisorCleanupWatchdogState: @unchecked Sendable {
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

func supervisorCleanupWatchdog(
    _ identity: SupervisorProcessIdentity?,
    supervisor: CodexProcessSupervisor
) -> SupervisorCleanupWatchdog {
    let state = SupervisorCleanupWatchdogState()
    let task = Task {
        do {
            try await Task.sleep(for: .seconds(8))
        } catch {
            return
        }
        guard state.claimFire() else { return }
        identity?.terminateIfStillMatching()
        await supervisor.cancel()
    }
    return SupervisorCleanupWatchdog(task: task, state: state)
}

enum SupervisorTestError: Error {
    case invalidPID
    case physicalPathUnavailable
    case pidWasNotPublished
}
