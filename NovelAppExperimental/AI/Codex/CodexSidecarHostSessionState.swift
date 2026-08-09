import Foundation
import NovelAI

struct CodexSidecarAttestedStart: Sendable {
    let command: CodexSidecarStartCommand

    fileprivate init(command: CodexSidecarStartCommand) {
        self.command = command
    }
}

struct CodexSidecarHostSessionState: Sendable {
    enum Phase: Sendable, Equatable {
        case awaitingHello
        case awaitingReady
        case attested
        case awaitingStarted
        case started
        case terminal
        case closed
    }

    let requestID: CodexSidecarRequestID
    let expectedRuntime: CodexSidecarRuntimeIdentity
    private(set) var phase: Phase = .awaitingHello
    private(set) var stdinByteCount = 0
    private var cancelWasSent = false

    init(
        requestID: CodexSidecarRequestID,
        expectedRuntime: CodexSidecarRuntimeIdentity
    ) {
        self.requestID = requestID
        self.expectedRuntime = expectedRuntime
    }

    mutating func encodeHelloFrame() throws -> Data {
        guard phase != .closed else {
            throw CodexSidecarLocalError.sessionUnavailable
        }
        guard phase == .awaitingHello else {
            throw CodexSidecarLocalError.helloAlreadySent
        }
        let frame = try CodexSidecarMessageCodec.encodeCommandFrame(
            .hello(CodexSidecarHelloCommand(requestID: requestID))
        )
        try accountForStdin(frame)
        phase = .awaitingReady
        return frame
    }

    mutating func encodeStartFrame(applicationPayload: AIApplicationPayload) throws -> Data {
        guard phase != .closed else {
            throw CodexSidecarLocalError.sessionUnavailable
        }
        guard phase == .attested else {
            if phase == .awaitingHello || phase == .awaitingReady {
                throw CodexSidecarLocalError.startBeforeAttestation
            }
            throw CodexSidecarLocalError.startAlreadySent
        }
        let start = try CodexSidecarStartCommand(
            requestID: requestID,
            applicationPayload: applicationPayload
        )
        let frame = try CodexSidecarMessageCodec.encodeAttestedStartFrame(
            CodexSidecarAttestedStart(command: start)
        )
        try accountForStdin(frame)
        phase = .awaitingStarted
        return frame
    }

    mutating func encodeCancelFrame() throws -> Data {
        guard phase != .closed else {
            throw CodexSidecarLocalError.sessionUnavailable
        }
        switch phase {
        case .awaitingHello, .awaitingReady, .attested:
            throw CodexSidecarLocalError.cancelBeforeStart
        case .terminal:
            throw CodexSidecarLocalError.cancelAfterTerminal
        case .awaitingStarted, .started:
            break
        case .closed:
            throw CodexSidecarLocalError.sessionUnavailable
        }
        guard !cancelWasSent else {
            throw CodexSidecarLocalError.duplicateCancel
        }
        let frame = try CodexSidecarMessageCodec.encodeCommandFrame(
            .cancel(CodexSidecarCancelCommand(requestID: requestID))
        )
        try accountForStdin(frame)
        cancelWasSent = true
        return frame
    }

    mutating func accept(_ event: CodexSidecarEvent) throws {
        guard phase != .closed else {
            throw CodexSidecarLocalError.sessionUnavailable
        }
        guard event.requestID == requestID else {
            phase = .closed
            throw CodexSidecarLocalError.wrongRequestID
        }

        switch event {
        case let .ready(_, runtime):
            try acceptReady(runtime)
        case .started:
            try acceptStarted()
        case .completed:
            try acceptCompleted()
        case let .failed(_, code):
            try acceptFailed(code)
        }
    }

    mutating func finishAtEOF() throws {
        guard phase == .terminal else {
            phase = .closed
            throw CodexSidecarLocalError.unexpectedEOF
        }
        phase = .closed
    }

    private mutating func acceptReady(_ runtime: CodexSidecarRuntimeIdentity) throws {
        guard phase == .awaitingReady else {
            phase = .closed
            throw CodexSidecarLocalError.unexpectedReady
        }
        guard runtime == expectedRuntime else {
            phase = .closed
            throw CodexSidecarLocalError.runtimeIdentityMismatch
        }
        phase = .attested
    }

    private mutating func acceptStarted() throws {
        switch phase {
        case .awaitingStarted:
            phase = .started
        case .started:
            phase = .closed
            throw CodexSidecarLocalError.duplicateStarted
        case .terminal:
            phase = .closed
            throw CodexSidecarLocalError.eventAfterTerminal
        case .awaitingHello, .awaitingReady, .attested:
            phase = .closed
            throw CodexSidecarLocalError.eventBeforeStart
        case .closed:
            throw CodexSidecarLocalError.sessionUnavailable
        }
    }

    private mutating func acceptCompleted() throws {
        switch phase {
        case .started:
            phase = .terminal
        case .awaitingStarted:
            phase = .closed
            throw CodexSidecarLocalError.completedBeforeStarted
        case .terminal:
            phase = .closed
            throw CodexSidecarLocalError.duplicateTerminal
        case .awaitingHello, .awaitingReady, .attested:
            phase = .closed
            throw CodexSidecarLocalError.eventBeforeStart
        case .closed:
            throw CodexSidecarLocalError.sessionUnavailable
        }
    }

    private mutating func acceptFailed(_: CodexSidecarFailureCode) throws {
        switch phase {
        case .started:
            phase = .terminal
        case .awaitingStarted:
            phase = .closed
            throw CodexSidecarLocalError.failedBeforeStarted
        case .terminal:
            phase = .closed
            throw CodexSidecarLocalError.duplicateTerminal
        case .awaitingHello, .awaitingReady, .attested:
            phase = .closed
            throw CodexSidecarLocalError.eventBeforeStart
        case .closed:
            throw CodexSidecarLocalError.sessionUnavailable
        }
    }

    private mutating func accountForStdin(_ frame: Data) throws {
        let total = stdinByteCount.addingReportingOverflow(frame.count)
        let actual = total.overflow ? Int.max : total.partialValue
        guard !total.overflow, actual <= CodexSidecarFrameDecoder.maximumStreamBytes else {
            phase = .closed
            throw CodexSidecarLocalError.streamByteLimitExceeded(
                limit: CodexSidecarFrameDecoder.maximumStreamBytes,
                actual: actual
            )
        }
        stdinByteCount = actual
    }
}
