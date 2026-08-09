import Foundation
import NovelAI

#if !FUMINIWA_ENABLE_EXPERIMENTAL_AI
#error("Codex synthetic interactive transport must only compile in FUMINIWAExperimental")
#endif

enum CodexSyntheticChannelOperation: Sendable, Equatable {
    case writeHello
    case readAttestation
    case writeStart
    case readResponse
    case requestCancellation
}

enum CodexSyntheticInteractiveTransportError: Error, Sendable, Equatable {
    case nonMockRuntimeExpectation
    case invalidAttestationTimeout
    case alreadyRunning
    case reusedChannel
    case channelOpenFailed
    case channelIOFailed(CodexSyntheticChannelOperation)
    case protocolFailure(CodexSidecarLocalError)
    case attestationFrameNotIsolated
    case attestationTimedOut
    case requestTimedOut
    case terminalDrainTimedOut
    case cancelled
    case cleanupFailed
}

struct CodexSyntheticMockRuntimeExpectation: Sendable, Equatable {
    let identity: CodexSidecarRuntimeIdentity

    init(_ identity: CodexSidecarRuntimeIdentity) throws {
        guard identity.mode == .mock else {
            throw CodexSyntheticInteractiveTransportError.nonMockRuntimeExpectation
        }
        self.identity = identity
    }
}

// Kept explicit because this request is the only content-bearing transport input.
// swiftlint:disable:next type_name
struct CodexSyntheticInteractiveTransportRequest: Sendable {
    static let maximumAttestationTimeout: Duration = .seconds(30)
    static let terminalDrainTimeout: Duration = .seconds(1)

    let requestID: CodexSidecarRequestID
    let expectedRuntime: CodexSyntheticMockRuntimeExpectation
    let applicationPayload: AIApplicationPayload
    let attestationTimeout: Duration

    var requestTimeout: Duration {
        .seconds(applicationPayload.budget.timeoutSeconds)
    }

    init(
        requestID: CodexSidecarRequestID,
        expectedRuntime: CodexSyntheticMockRuntimeExpectation,
        applicationPayload: AIApplicationPayload,
        attestationTimeout: Duration
    ) throws {
        let timeoutIsValid = attestationTimeout > .zero
            && attestationTimeout <= Self.maximumAttestationTimeout
        guard timeoutIsValid else {
            throw CodexSyntheticInteractiveTransportError.invalidAttestationTimeout
        }
        self.requestID = requestID
        self.expectedRuntime = expectedRuntime
        self.applicationPayload = applicationPayload
        self.attestationTimeout = attestationTimeout
    }
}

enum CodexSyntheticInteractiveTerminal: Sendable, Equatable {
    case completed(structuredOutput: String, usage: CodexSidecarUsage)
    case failed(CodexSidecarFailureCode)
}

protocol CodexSyntheticInteractiveChannel: AnyObject, Sendable {
    /// Writes exactly one already-framed command without coalescing other data.
    func write(_ frame: Data) async throws

    /// Returns the next byte chunk, or `nil` only for EOF. Empty chunks are
    /// invalid and are rejected by the transport.
    func read() async throws -> Data?

    /// Atomically emits `cancelFrame`, when present, before interrupting any
    /// pending read or write. The frame must never be split, extended, or
    /// interleaved with `write`. Pending operations must settle even on throw.
    func requestCancellation(cancelFrame: Data?) async throws

    /// Settles all channel activity and releases request content before return.
    func cleanup() async throws
}

protocol CodexSyntheticInteractiveChannelFactory: Sendable {
    /// Opens an empty transport without receiving request, payload, identity,
    /// path, or any other content-bearing argument. Before throwing, the
    /// factory must clean every partial allocation that it owns. Every success
    /// must return a fresh one-request channel never returned by any prior call,
    /// including calls made through another transport sharing this factory.
    func openContentFree() async throws -> any CodexSyntheticInteractiveChannel

    /// Makes a pending `openContentFree` settle. A fresh late returned channel
    /// is claimed and cleaned before `run` returns. A channel already claimed
    /// by another session is rejected without disturbing that owner. Returning
    /// from this hook acknowledges the request, not a hard wall-clock bound;
    /// the pending open must still settle even when this hook throws.
    func requestOpenCancellation() async throws
}
