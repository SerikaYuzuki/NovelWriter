@testable import FUMINIWAExperimental
import Testing

@Test("host stateはexact ready attestation前のstartをencodeしない")
func hostStateRequiresExactReadyBeforeStart() throws {
    let preview = try productionPreview()
    var session = CodexSidecarHostSessionState(
        requestID: protocolRequestID,
        expectedRuntime: mockRuntimeIdentity
    )

    expectSidecarError(.startBeforeAttestation) {
        _ = try session.encodeStartFrame(applicationPayload: preview.applicationPayload)
    }
    let hello = try session.encodeHelloFrame()
    try expectJSONFramesEquivalent(hello, fixtureData(named: "hello"))
    #expect(session.phase == .awaitingReady)
    expectSidecarError(.helloAlreadySent) {
        _ = try session.encodeHelloFrame()
    }

    try session.accept(.ready(requestID: protocolRequestID, runtime: mockRuntimeIdentity))
    #expect(session.phase == .attested)
    _ = try session.encodeStartFrame(applicationPayload: preview.applicationPayload)
    #expect(session.phase == .awaitingStarted)
    expectSidecarError(.startAlreadySent) {
        _ = try session.encodeStartFrame(applicationPayload: preview.applicationPayload)
    }
}

@Test("ready identityまたはrequest ID不一致はcontent送信前にsessionを閉じる")
func hostStateRejectsReadyMismatchBeforeContent() throws {
    let differentRuntime = try CodexSidecarRuntimeIdentity(
        mode: .mock,
        sidecarVersion: "protocol-v1-drifted",
        sidecarBundleSHA256: nil,
        nodeVersion: "0.0.0-test",
        nodeSHA256: nil,
        architecture: .arm64,
        sdkVersion: nil,
        sdkIntegrity: nil,
        cliVersion: nil,
        cliSHA256: nil
    )
    var runtimeMismatch = CodexSidecarHostSessionState(
        requestID: protocolRequestID,
        expectedRuntime: mockRuntimeIdentity
    )
    _ = try runtimeMismatch.encodeHelloFrame()
    expectSidecarError(.runtimeIdentityMismatch) {
        try runtimeMismatch.accept(
            .ready(requestID: protocolRequestID, runtime: differentRuntime)
        )
    }
    #expect(runtimeMismatch.phase == .closed)
    expectSidecarError(.sessionUnavailable) {
        _ = try runtimeMismatch.encodeStartFrame(
            applicationPayload: productionPreview().applicationPayload
        )
    }

    var wrongID = CodexSidecarHostSessionState(
        requestID: protocolRequestID,
        expectedRuntime: mockRuntimeIdentity
    )
    _ = try wrongID.encodeHelloFrame()
    expectSidecarError(.wrongRequestID) {
        try wrongID.accept(.ready(requestID: otherProtocolRequestID, runtime: mockRuntimeIdentity))
    }
    #expect(wrongID.phase == .closed)
}

@Test("valid start後もstartedより前のterminalと異なるrequest IDを拒否する")
func hostStateRequiresStartedBeforeTerminal() throws {
    var failedBeforeStarted = try sessionAfterStart()
    expectSidecarError(.failedBeforeStarted) {
        try failedBeforeStarted.accept(
            .failed(requestID: protocolRequestID, code: .providerUnavailable)
        )
    }

    var completedBeforeStarted = try sessionAfterStart()
    expectSidecarError(.completedBeforeStarted) {
        try completedBeforeStarted.accept(
            .completed(
                requestID: protocolRequestID,
                structuredOutput: "{}",
                usage: CodexSidecarUsage(inputTokens: nil, outputTokens: 0)
            )
        )
    }

    var wrongID = try sessionAfterStart()
    expectSidecarError(.wrongRequestID) {
        try wrongID.accept(.started(requestID: otherProtocolRequestID))
    }
}

@Test("started後の最初のterminalだけを受理しduplicateとlate eventを拒否する")
func hostStateAllowsSingleTerminal() throws {
    let completed = try CodexSidecarEvent.completed(
        requestID: protocolRequestID,
        structuredOutput: "{}",
        usage: CodexSidecarUsage(inputTokens: nil, outputTokens: 0)
    )
    var duplicateTerminal = try sessionAfterStart()
    try duplicateTerminal.accept(.started(requestID: protocolRequestID))
    try duplicateTerminal.accept(completed)
    #expect(duplicateTerminal.phase == .terminal)
    expectSidecarError(.duplicateTerminal) {
        try duplicateTerminal.accept(
            .failed(requestID: protocolRequestID, code: .providerUnavailable)
        )
    }
    #expect(duplicateTerminal.phase == .closed)

    var lateStarted = try sessionAfterStart()
    try lateStarted.accept(.started(requestID: protocolRequestID))
    try lateStarted.accept(completed)
    expectSidecarError(.eventAfterTerminal) {
        try lateStarted.accept(.started(requestID: protocolRequestID))
    }
    #expect(lateStarted.phase == .closed)
}

@Test("cancelは1回だけencodeしackなしraceの最初のvalid terminalを受理する")
func hostStateHandlesCancelWithoutAssumingAcknowledgement() throws {
    var completedWins = try sessionAfterStart()
    _ = try completedWins.encodeCancelFrame()
    expectSidecarError(.duplicateCancel) {
        _ = try completedWins.encodeCancelFrame()
    }
    try completedWins.accept(.started(requestID: protocolRequestID))
    try completedWins.accept(
        .completed(
            requestID: protocolRequestID,
            structuredOutput: "{}",
            usage: CodexSidecarUsage(inputTokens: nil, outputTokens: 0)
        )
    )
    #expect(completedWins.phase == .terminal)
    expectSidecarError(.cancelAfterTerminal) {
        _ = try completedWins.encodeCancelFrame()
    }

    var failureWins = try sessionAfterStart()
    _ = try failureWins.encodeCancelFrame()
    try failureWins.accept(.started(requestID: protocolRequestID))
    try failureWins.accept(
        .failed(requestID: protocolRequestID, code: .providerUnavailable)
    )
    #expect(failureWins.phase == .terminal)

    var cancellationWins = try sessionAfterStart()
    _ = try cancellationWins.encodeCancelFrame()
    try cancellationWins.accept(.started(requestID: protocolRequestID))
    try cancellationWins.accept(.failed(requestID: protocolRequestID, code: .cancelled))
    #expect(cancellationWins.phase == .terminal)
}

@Test("EOFはterminal後だけ正常でhandshake中・running中はfail closedする")
func hostStateRejectsPrematureEOF() throws {
    var duringHandshake = CodexSidecarHostSessionState(
        requestID: protocolRequestID,
        expectedRuntime: mockRuntimeIdentity
    )
    _ = try duringHandshake.encodeHelloFrame()
    expectSidecarError(.unexpectedEOF) {
        try duringHandshake.finishAtEOF()
    }
    #expect(duringHandshake.phase == .closed)

    var whileRunning = try sessionAfterStart()
    expectSidecarError(.unexpectedEOF) {
        try whileRunning.finishAtEOF()
    }
    #expect(whileRunning.phase == .closed)

    var afterTerminal = try sessionAfterStart()
    try afterTerminal.accept(.started(requestID: protocolRequestID))
    try afterTerminal.accept(.failed(requestID: protocolRequestID, code: .cancelled))
    try afterTerminal.finishAtEOF()
    #expect(afterTerminal.phase == .closed)
    expectSidecarError(.sessionUnavailable) {
        try afterTerminal.accept(.started(requestID: protocolRequestID))
    }
}
