import Darwin
import Foundation

#if !FUMINIWA_ENABLE_EXPERIMENTAL_AI
#error("Codex process supervision must only compile in FUMINIWAExperimental")
#endif

final class CodexProcessIO: @unchecked Sendable {
    private let inputWriter: CodexProcessInputWriter
    private let outputCapture: CodexProcessBoundedCapture
    private let errorCapture: CodexProcessBoundedCapture
    private let group = DispatchGroup()

    init(
        stdinDescriptor: Int32,
        stdoutDescriptor: Int32,
        stderrDescriptor: Int32,
        input: Data,
        deadline: ContinuousClock.Instant,
        state: CodexProcessState
    ) {
        inputWriter = CodexProcessInputWriter(
            descriptor: stdinDescriptor,
            input: input,
            deadline: deadline,
            state: state
        )
        outputCapture = CodexProcessBoundedCapture(
            descriptor: stdoutDescriptor,
            limit: CodexProcessInvocation.maximumStandardOutputBytes,
            retainBytes: true,
            overflowError: { actual in
                .standardOutputLimitExceeded(
                    limit: CodexProcessInvocation.maximumStandardOutputBytes,
                    actualAtLeast: actual
                )
            },
            state: state
        )
        errorCapture = CodexProcessBoundedCapture(
            descriptor: stderrDescriptor,
            limit: CodexProcessInvocation.maximumStandardErrorBytes,
            retainBytes: false,
            overflowError: { actual in
                .standardErrorLimitExceeded(
                    limit: CodexProcessInvocation.maximumStandardErrorBytes,
                    actualAtLeast: actual
                )
            },
            state: state
        )
        let queue = DispatchQueue(
            label: "dev.serikayuzuki.fuminiwa.codex-process-io",
            qos: .userInitiated,
            attributes: .concurrent
        )
        queue.async(group: group) { [inputWriter] in inputWriter.run() }
        queue.async(group: group) { [outputCapture] in outputCapture.run() }
        queue.async(group: group) { [errorCapture] in errorCapture.run() }
    }

    var standardOutput: Data {
        outputCapture.retainedData
    }

    var standardErrorByteCount: Int {
        errorCapture.byteCount
    }

    var failure: CodexProcessSupervisorError? {
        inputWriter.failure ?? outputCapture.failure ?? errorCapture.failure
    }

    func finish(gracePeriod: Duration) throws {
        let firstWait = max(gracePeriod, .seconds(1))
        if group.wait(timeout: .now() + dispatchInterval(for: firstWait)) == .success {
            return
        }
        inputWriter.requestStop()
        outputCapture.requestStop()
        errorCapture.requestStop()
        guard group.wait(timeout: .now() + .seconds(1)) == .success else {
            throw CodexProcessSupervisorError.ioWorkersFailedToStop
        }
        throw CodexProcessSupervisorError.ioDrainTimedOut
    }

    private func dispatchInterval(for duration: Duration) -> DispatchTimeInterval {
        let components = duration.components
        let seconds = min(max(components.seconds, 0), 10)
        let fractional = max(components.attoseconds, 0) / 1_000_000_000
        let nanoseconds = seconds * 1_000_000_000 + min(fractional, 999_999_999)
        return .nanoseconds(Int(nanoseconds))
    }
}

private final class CodexProcessInputWriter: @unchecked Sendable {
    private let descriptor: Int32
    private let input: Data
    private let deadline: ContinuousClock.Instant
    private let state: CodexProcessState
    private let lock = NSLock()
    private var storedFailure: CodexProcessSupervisorError?
    private var stopRequested = false

    init(
        descriptor: Int32,
        input: Data,
        deadline: ContinuousClock.Instant,
        state: CodexProcessState
    ) {
        self.descriptor = descriptor
        self.input = input
        self.deadline = deadline
        self.state = state
    }

    var failure: CodexProcessSupervisorError? {
        lock.withLock { storedFailure }
    }

    func requestStop() {
        lock.withLock { stopRequested = true }
    }

    func run() {
        defer { _ = close(descriptor) }
        input.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count, !shouldStop {
                let written = write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written == -1, errno == EINTR || errno == EAGAIN {
                    CodexProcessRunner.sleepBriefly()
                } else if written == -1 {
                    recordFailure(.inputWriteFailed(code: errno))
                    return
                }
            }
        }
    }

    private var shouldStop: Bool {
        state.shouldStopInput(deadline: deadline)
            || lock.withLock { stopRequested }
    }

    private func recordFailure(_ error: CodexProcessSupervisorError) {
        lock.withLock { storedFailure = storedFailure ?? error }
        state.requestStop(.failure(error))
    }
}

private final class CodexProcessBoundedCapture: @unchecked Sendable {
    private let descriptor: Int32
    private let limit: Int
    private let retainBytes: Bool
    private let overflowError: @Sendable (Int) -> CodexProcessSupervisorError
    private let state: CodexProcessState
    private let lock = NSLock()
    private var data = Data()
    private var count = 0
    private var storedFailure: CodexProcessSupervisorError?
    private var stopRequested = false

    init(
        descriptor: Int32,
        limit: Int,
        retainBytes: Bool,
        overflowError: @escaping @Sendable (Int) -> CodexProcessSupervisorError,
        state: CodexProcessState
    ) {
        self.descriptor = descriptor
        self.limit = limit
        self.retainBytes = retainBytes
        self.overflowError = overflowError
        self.state = state
    }

    var retainedData: Data {
        lock.withLock { data }
    }

    var byteCount: Int {
        lock.withLock { count }
    }

    var failure: CodexProcessSupervisorError? {
        lock.withLock { storedFailure }
    }

    func requestStop() {
        lock.withLock { stopRequested = true }
    }

    func run() {
        defer { _ = close(descriptor) }
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while !lock.withLock({ stopRequested }) {
            let readCount = buffer.withUnsafeMutableBytes { bytes in
                read(descriptor, bytes.baseAddress, bytes.count)
            }
            if readCount > 0 {
                consume(buffer, readCount: readCount)
            } else if readCount == 0 {
                return
            } else if errno == EINTR || errno == EAGAIN {
                CodexProcessRunner.sleepBriefly()
            } else {
                recordFailure(
                    .systemCallFailed(operation: "read(pipe)", code: errno)
                )
                return
            }
        }
    }

    private func consume(_ buffer: [UInt8], readCount: Int) {
        let failure: CodexProcessSupervisorError? = lock.withLock {
            let addition = count.addingReportingOverflow(readCount)
            count = addition.overflow ? Int.max : addition.partialValue
            if retainBytes, data.count < limit {
                data.append(
                    contentsOf: buffer.prefix(min(readCount, limit - data.count))
                )
            }
            guard count > limit, storedFailure == nil else { return nil }
            let error = overflowError(count)
            storedFailure = error
            return error
        }
        if let failure {
            state.requestStop(.failure(failure))
        }
    }

    private func recordFailure(_ error: CodexProcessSupervisorError) {
        lock.withLock { storedFailure = storedFailure ?? error }
        state.requestStop(.failure(error))
    }
}
