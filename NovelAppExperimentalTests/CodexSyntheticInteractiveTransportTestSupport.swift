import Foundation
@testable import FUMINIWAExperimental
import NovelAI
import Testing

// Shared deterministic channel/factory fixtures intentionally stay together.
// swiftlint:disable file_length

enum SyntheticInteractiveReadStep: Sendable {
    case bytes(Data)
    case endOfFile
    case failure(SyntheticInteractiveRawError)
    case waitForTaskCancellation
    case blocked(
        gate: SyntheticInteractiveGate,
        result: SyntheticInteractiveBlockedReadResult
    )
}

enum SyntheticInteractiveBlockedReadResult: Sendable {
    case bytes(Data)
    case endOfFile
    case failure(SyntheticInteractiveRawError)
}

enum SyntheticInteractiveWriteStep: Sendable {
    case succeed
    case failure(SyntheticInteractiveRawError)
    case blocked(
        gate: SyntheticInteractiveGate,
        result: SyntheticInteractiveBlockedWriteResult
    )
}

enum SyntheticInteractiveBlockedWriteResult: Sendable {
    case succeed
    case failure(SyntheticInteractiveRawError)
}

enum SyntheticInteractiveFactoryResult: Sendable {
    case channel(SyntheticInteractiveChannel)
    case failure(SyntheticInteractiveRawError)
}

struct SyntheticInteractiveRawError: Error, Sendable, CustomStringConvertible {
    let description: String

    static let secret = Self(
        description: "raw-secret=synthetic-api-key path=/private/secret/manuscript.novelpkg"
    )
}

final class SyntheticInteractiveWeakChannelProbe: @unchecked Sendable {
    weak var channel: SyntheticInteractiveChannel?

    init(channel: SyntheticInteractiveChannel) {
        self.channel = channel
    }
}

actor SyntheticInteractiveGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        pending.forEach { $0.resume() }
    }
}

actor SyntheticInteractiveTranscript {
    private(set) var factoryOpenCount = 0
    private(set) var factoryCancellationCount = 0
    private(set) var writes: [Data] = []
    private(set) var readCount = 0
    private(set) var cancellationCount = 0
    private(set) var cleanupCount = 0
    private(set) var ioAfterCleanupCount = 0

    func recordFactoryOpen() {
        factoryOpenCount += 1
    }

    func recordFactoryCancellation() {
        factoryCancellationCount += 1
    }

    func recordWrite(_ data: Data) {
        if cleanupCount > 0 {
            ioAfterCleanupCount += 1
        }
        writes.append(data)
    }

    func recordRead() {
        if cleanupCount > 0 {
            ioAfterCleanupCount += 1
        }
        readCount += 1
    }

    func recordCancellation(cancelFrame: Data?) {
        if cleanupCount > 0 {
            ioAfterCleanupCount += 1
        }
        cancellationCount += 1
        if let cancelFrame {
            writes.append(cancelFrame)
        }
    }

    func recordCleanup() {
        cleanupCount += 1
    }

    func commandFrames() throws -> [CodexSidecarCommand] {
        try writes.map(decodeSingleCommandFrame)
    }

    func startWriteCount() throws -> Int {
        try commandFrames().reduce(into: 0) { count, command in
            if case .start = command {
                count += 1
            }
        }
    }

    func cancelWriteCount() throws -> Int {
        try commandFrames().reduce(into: 0) { count, command in
            if case .cancel = command {
                count += 1
            }
        }
    }
}

actor SyntheticInteractiveChannel: CodexSyntheticInteractiveChannel {
    private let transcript: SyntheticInteractiveTranscript
    private var readSteps: [SyntheticInteractiveReadStep]
    private var writeSteps: [SyntheticInteractiveWriteStep]
    private let cancellationFailure: SyntheticInteractiveRawError?
    private let cancellationWriteStep: SyntheticInteractiveWriteStep?
    private let cleanupFailure: SyntheticInteractiveRawError?
    private let cleanupGate: SyntheticInteractiveGate?
    private var blockedGate: SyntheticInteractiveGate?
    private var cancellationWasRequested = false

    init(
        transcript: SyntheticInteractiveTranscript,
        readSteps: [SyntheticInteractiveReadStep],
        writeSteps: [SyntheticInteractiveWriteStep] = [],
        cancellationFailure: SyntheticInteractiveRawError? = nil,
        cancellationWriteStep: SyntheticInteractiveWriteStep? = nil,
        cleanupFailure: SyntheticInteractiveRawError? = nil,
        cleanupGate: SyntheticInteractiveGate? = nil
    ) {
        self.transcript = transcript
        self.readSteps = readSteps
        self.writeSteps = writeSteps
        self.cancellationFailure = cancellationFailure
        self.cancellationWriteStep = cancellationWriteStep
        self.cleanupFailure = cleanupFailure
        self.cleanupGate = cleanupGate
    }

    func write(_ frame: Data) async throws {
        await transcript.recordWrite(frame)
        guard !writeSteps.isEmpty else { return }
        let step = writeSteps.removeFirst()
        switch step {
        case .succeed:
            return
        case let .failure(error):
            throw error
        case let .blocked(gate, result):
            blockedGate = gate
            if cancellationWasRequested {
                await gate.open()
            }
            await gate.wait()
            blockedGate = nil
            switch result {
            case .succeed:
                return
            case let .failure(error):
                throw error
            }
        }
    }

    func read() async throws -> Data? {
        await transcript.recordRead()
        guard !readSteps.isEmpty else { return nil }
        let step = readSteps.removeFirst()
        switch step {
        case let .bytes(data):
            return data
        case .endOfFile:
            return nil
        case let .failure(error):
            throw error
        case .waitForTaskCancellation:
            do {
                try await Task.sleep(for: .seconds(60))
                return nil
            } catch {
                throw CancellationError()
            }
        case let .blocked(gate, result):
            blockedGate = gate
            await gate.wait()
            blockedGate = nil
            switch result {
            case let .bytes(data):
                return data
            case .endOfFile:
                return nil
            case let .failure(error):
                throw error
            }
        }
    }

    func requestCancellation(cancelFrame: Data?) async throws {
        await transcript.recordCancellation(cancelFrame: cancelFrame)
        cancellationWasRequested = true
        await blockedGate?.open()
        if cancelFrame != nil, let cancellationWriteStep {
            try await performCancellationWriteStep(cancellationWriteStep)
        }
        if let cancellationFailure {
            throw cancellationFailure
        }
    }

    func cleanup() async throws {
        await transcript.recordCleanup()
        await cleanupGate?.wait()
        if let cleanupFailure {
            throw cleanupFailure
        }
    }

    private func performCancellationWriteStep(
        _ step: SyntheticInteractiveWriteStep
    ) async throws {
        switch step {
        case .succeed:
            return
        case let .failure(error):
            throw error
        case let .blocked(gate, result):
            await gate.open()
            await gate.wait()
            switch result {
            case .succeed:
                return
            case let .failure(error):
                throw error
            }
        }
    }
}

actor SyntheticInteractiveFactory: CodexSyntheticInteractiveChannelFactory {
    private let transcript: SyntheticInteractiveTranscript
    private let gate: SyntheticInteractiveGate?
    private let result: SyntheticInteractiveFactoryResult
    private let openCancellationFailure: SyntheticInteractiveRawError?

    init(
        transcript: SyntheticInteractiveTranscript,
        gate: SyntheticInteractiveGate? = nil,
        result: SyntheticInteractiveFactoryResult,
        openCancellationFailure: SyntheticInteractiveRawError? = nil
    ) {
        self.transcript = transcript
        self.gate = gate
        self.result = result
        self.openCancellationFailure = openCancellationFailure
    }

    func openContentFree() async throws -> any CodexSyntheticInteractiveChannel {
        await transcript.recordFactoryOpen()
        if let gate {
            await gate.wait()
        }
        switch result {
        case let .channel(channel):
            return channel
        case let .failure(error):
            throw error
        }
    }

    func requestOpenCancellation() async throws {
        await transcript.recordFactoryCancellation()
        await gate?.open()
        if let openCancellationFailure {
            throw openCancellationFailure
        }
    }
}

actor SyntheticInteractiveSequenceFactory: CodexSyntheticInteractiveChannelFactory {
    private let transcript: SyntheticInteractiveTranscript
    private var results: [SyntheticInteractiveFactoryResult]

    init(
        transcript: SyntheticInteractiveTranscript,
        results: [SyntheticInteractiveFactoryResult]
    ) {
        self.transcript = transcript
        self.results = results
    }

    func openContentFree() async throws -> any CodexSyntheticInteractiveChannel {
        await transcript.recordFactoryOpen()
        guard !results.isEmpty else {
            throw SyntheticInteractiveRawError.secret
        }
        switch results.removeFirst() {
        case let .channel(channel):
            return channel
        case let .failure(error):
            throw error
        }
    }

    func requestOpenCancellation() async throws {
        await transcript.recordFactoryCancellation()
    }
}

actor SyntheticCooperativeFactory: CodexSyntheticInteractiveChannelFactory {
    private let transcript: SyntheticInteractiveTranscript
    private let cancellationGate = SyntheticInteractiveGate()

    init(
        transcript: SyntheticInteractiveTranscript,
        channel _: SyntheticInteractiveChannel
    ) {
        self.transcript = transcript
    }

    func openContentFree() async throws -> any CodexSyntheticInteractiveChannel {
        await transcript.recordFactoryOpen()
        await cancellationGate.wait()
        try Task.checkCancellation()
        throw CancellationError()
    }

    func requestOpenCancellation() async throws {
        await transcript.recordFactoryCancellation()
        await cancellationGate.open()
    }
}

actor SyntheticInteractiveLateReturningFactory: CodexSyntheticInteractiveChannelFactory {
    private let transcript: SyntheticInteractiveTranscript
    private let channel: SyntheticInteractiveChannel
    private let delay: Duration

    init(
        transcript: SyntheticInteractiveTranscript,
        channel: SyntheticInteractiveChannel,
        delay: Duration
    ) {
        self.transcript = transcript
        self.channel = channel
        self.delay = delay
    }

    func openContentFree() async throws -> any CodexSyntheticInteractiveChannel {
        await transcript.recordFactoryOpen()
        await Task.detached { [delay] in
            try? await Task.sleep(for: delay)
        }.value
        return channel
    }

    func requestOpenCancellation() async throws {
        await transcript.recordFactoryCancellation()
    }
}

func syntheticReadyFrame(
    requestID: CodexSidecarRequestID = protocolRequestID,
    runtime: CodexSidecarRuntimeIdentity = mockRuntimeIdentity
) throws -> Data {
    try CodexSidecarMessageCodec.encodeEventFrame(
        .ready(requestID: requestID, runtime: runtime)
    )
}

func syntheticStartedFrame(
    requestID: CodexSidecarRequestID = protocolRequestID
) throws -> Data {
    try CodexSidecarMessageCodec.encodeEventFrame(.started(requestID: requestID))
}

func syntheticCompletedFrame(
    requestID: CodexSidecarRequestID = protocolRequestID,
    structuredOutput: String = #"{"replacement":"synthetic","summary":"test","warnings":[]}"#
) throws -> Data {
    try CodexSidecarMessageCodec.encodeEventFrame(
        .completed(
            requestID: requestID,
            structuredOutput: structuredOutput,
            usage: CodexSidecarUsage(inputTokens: 1, outputTokens: 1)
        )
    )
}

func syntheticFailedFrame(
    requestID: CodexSidecarRequestID = protocolRequestID,
    code: CodexSidecarFailureCode = .providerUnavailable
) throws -> Data {
    try CodexSidecarMessageCodec.encodeEventFrame(
        .failed(requestID: requestID, code: code)
    )
}

func syntheticInvalidReadyFrame(extraMember: String) -> Data {
    Data(
        // swiftlint:disable:next line_length
        (#"{"version":1,"type":"ready","request_id":"\#(protocolRequestIDText)","runtime":{"mode":"mock","sidecar_version":"protocol-v1-test","sidecar_bundle_sha256":null,"node_version":"0.0.0-test","node_sha256":null,"architecture":"arm64","sdk_version":null,"sdk_integrity":null,"cli_version":null,"cli_sha256":null},"extra":"\#(extraMember)"}"# + "\n").utf8
    )
}

func syntheticInteractivePayload() throws -> AIApplicationPayload {
    try productionPreview().applicationPayload
}

func syntheticInteractiveRequest(
    requestID: CodexSidecarRequestID = protocolRequestID,
    runtime: CodexSidecarRuntimeIdentity = mockRuntimeIdentity,
    applicationPayload: AIApplicationPayload? = nil,
    attestationTimeout: Duration = .seconds(1)
) throws -> CodexSyntheticInteractiveTransportRequest {
    try CodexSyntheticInteractiveTransportRequest(
        requestID: requestID,
        expectedRuntime: CodexSyntheticMockRuntimeExpectation(runtime),
        applicationPayload: applicationPayload ?? syntheticInteractivePayload(),
        attestationTimeout: attestationTimeout
    )
}

func syntheticInteractivePayload(timeoutSeconds: Int) throws -> AIApplicationPayload {
    let budget = AIRequestBudget(
        maximumInputCharacters: 20000,
        maximumInputUTF8Bytes: 80000,
        maximumOutputCharacters: 20000,
        maximumOutputUTF8Bytes: 80000,
        maximumOutputTokens: 4096,
        maximumWarnings: 20,
        timeoutSeconds: timeoutSeconds
    )
    return try AIRequestDraft(
        selectedText: "synthetic selection",
        budget: budget
    ).preview(for: codexSidecarDescriptor).applicationPayload
}

func syntheticInteractiveHarness(
    readSteps: [SyntheticInteractiveReadStep],
    writeSteps: [SyntheticInteractiveWriteStep] = [],
    cancellationFailure: SyntheticInteractiveRawError? = nil,
    cancellationWriteStep: SyntheticInteractiveWriteStep? = nil,
    cleanupFailure: SyntheticInteractiveRawError? = nil,
    cleanupGate: SyntheticInteractiveGate? = nil,
    factoryGate: SyntheticInteractiveGate? = nil,
    factoryFailure: SyntheticInteractiveRawError? = nil,
    factoryCancellationFailure: SyntheticInteractiveRawError? = nil
) -> (
    transport: CodexSyntheticInteractiveTransport,
    transcript: SyntheticInteractiveTranscript
) {
    let transcript = SyntheticInteractiveTranscript()
    let channel = SyntheticInteractiveChannel(
        transcript: transcript,
        readSteps: readSteps,
        writeSteps: writeSteps,
        cancellationFailure: cancellationFailure,
        cancellationWriteStep: cancellationWriteStep,
        cleanupFailure: cleanupFailure,
        cleanupGate: cleanupGate
    )
    let factory = SyntheticInteractiveFactory(
        transcript: transcript,
        gate: factoryGate,
        result: factoryFailure.map(SyntheticInteractiveFactoryResult.failure)
            ?? .channel(channel),
        openCancellationFailure: factoryCancellationFailure
    )
    return (
        CodexSyntheticInteractiveTransport(factory: factory),
        transcript
    )
}

func capturedSyntheticInteractiveError(
    _ operation: () async throws -> Void
) async -> CodexSyntheticInteractiveTransportError? {
    do {
        try await operation()
        Issue.record("expected CodexSyntheticInteractiveTransportError")
        return nil
    } catch let error as CodexSyntheticInteractiveTransportError {
        return error
    } catch {
        Issue.record("unexpected error: \(error)")
        return nil
    }
}

func requiredSDKRuntimeIdentity() -> CodexSidecarRuntimeIdentity {
    do {
        return try sdkRuntimeIdentity(
            nodeSHA256: String(repeating: "a", count: 64),
            sdkIntegrity: "sha512-" + Data(repeating: 0x41, count: 64).base64EncodedString()
        )
    } catch {
        fatalError("invalid SDK runtime test identity")
    }
}

func waitForSyntheticWrites(
    _ expectedCount: Int,
    transcript: SyntheticInteractiveTranscript
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while clock.now < deadline {
        if await transcript.writes.count >= expectedCount {
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("transport did not produce \(expectedCount) writes")
}

func waitForSyntheticReads(
    _ expectedCount: Int,
    transcript: SyntheticInteractiveTranscript
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while clock.now < deadline {
        if await transcript.readCount >= expectedCount {
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("transport did not perform \(expectedCount) reads")
}

func waitForSyntheticFactoryOpens(
    _ expectedCount: Int,
    transcript: SyntheticInteractiveTranscript
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while clock.now < deadline {
        if await transcript.factoryOpenCount >= expectedCount {
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("transport did not open \(expectedCount) channels")
}

func waitForSyntheticCancellations(
    _ expectedCount: Int,
    transcript: SyntheticInteractiveTranscript
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while clock.now < deadline {
        if await transcript.cancellationCount >= expectedCount {
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("transport did not request \(expectedCount) channel cancellations")
}

func waitForSyntheticCleanups(
    _ expectedCount: Int,
    transcript: SyntheticInteractiveTranscript
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while clock.now < deadline {
        if await transcript.cleanupCount >= expectedCount {
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("transport did not clean up \(expectedCount) channels")
}

func expectNoRawSyntheticErrorDisclosure(_ error: any Error) {
    let rendered = String(reflecting: error)
    #expect(!rendered.contains("synthetic-api-key"))
    #expect(!rendered.contains("manuscript.novelpkg"))
    #expect(!rendered.contains("/private/secret"))
}
