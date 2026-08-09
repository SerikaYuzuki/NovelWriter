import Foundation
@testable import FUMINIWAExperimental
import Testing

@Suite("Codex synthetic interactive transport", .serialized)
struct CodexSyntheticInteractiveTransportTests {
    @Test("exact mock ready後だけstartを書きstarted・terminal・EOFを完了する")
    func exactReadyThenStartCompletes() async throws {
        let output = #"{"replacement":"synthetic","summary":"test","warnings":[]}"#
        let harness = try syntheticInteractiveHarness(
            readSteps: [
                .bytes(syntheticReadyFrame()),
                .bytes(syntheticStartedFrame()),
                .bytes(syntheticCompletedFrame(structuredOutput: output)),
                .endOfFile
            ]
        )
        let terminal = try await harness.transport.run(syntheticInteractiveRequest())

        #expect(
            try terminal == .completed(
                structuredOutput: output,
                usage: CodexSidecarUsage(inputTokens: 1, outputTokens: 1)
            )
        )
        #expect(await harness.transcript.factoryOpenCount == 1)
        #expect(await harness.transcript.cleanupCount == 1)
        #expect(await harness.transcript.cancellationCount == 0)

        let commands = try await harness.transcript.commandFrames()
        #expect(commands.count == 2)
        guard commands.count == 2 else { return }
        #expect(
            commands[0] == .hello(CodexSidecarHelloCommand(requestID: protocolRequestID))
        )
        #expect(
            try commands[1] == .start(
                CodexSidecarStartCommand(
                    requestID: protocolRequestID,
                    applicationPayload: syntheticInteractivePayload()
                )
            )
        )
    }

    @Test("failed terminalもstarted後かつEOF後だけ固定値として返す")
    func failedTerminalCompletesAtEOF() async throws {
        let harness = try syntheticInteractiveHarness(
            readSteps: [
                .bytes(syntheticReadyFrame()),
                .bytes(syntheticStartedFrame()),
                .bytes(syntheticFailedFrame(code: .providerUnavailable)),
                .endOfFile
            ]
        )

        let terminal = try await harness.transport.run(syntheticInteractiveRequest())

        #expect(terminal == .failed(.providerUnavailable))
        #expect(try await harness.transcript.startWriteCount() == 1)
        #expect(await harness.transcript.cleanupCount == 1)
    }

    @Test("codex_sdk expectationはfactoryを開く前に構築を拒否する")
    func nonMockExpectationCannotReachFactory() async {
        let transcript = SyntheticInteractiveTranscript()
        let channel = SyntheticInteractiveChannel(transcript: transcript, readSteps: [])
        let factory = SyntheticInteractiveFactory(
            transcript: transcript,
            result: .channel(channel)
        )
        _ = CodexSyntheticInteractiveTransport(factory: factory)

        do {
            _ = try CodexSyntheticMockRuntimeExpectation(requiredSDKRuntimeIdentity())
            Issue.record("expected nonMockRuntimeExpectation")
        } catch let error as CodexSyntheticInteractiveTransportError {
            #expect(error == .nonMockRuntimeExpectation)
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(await transcript.factoryOpenCount == 0)
        #expect(await transcript.writes.isEmpty)
    }

    @Test("attestation timeout boundsはfactoryを開く前に拒否する")
    func invalidAttestationTimeoutCannotReachFactory() async throws {
        let transcript = SyntheticInteractiveTranscript()
        let channel = SyntheticInteractiveChannel(transcript: transcript, readSteps: [])
        let factory = SyntheticInteractiveFactory(
            transcript: transcript,
            result: .channel(channel)
        )
        _ = CodexSyntheticInteractiveTransport(factory: factory)
        let expectation = try CodexSyntheticMockRuntimeExpectation(mockRuntimeIdentity)
        let payload = try syntheticInteractivePayload()

        for timeout in [Duration.zero, .seconds(31)] {
            do {
                _ = try CodexSyntheticInteractiveTransportRequest(
                    requestID: protocolRequestID,
                    expectedRuntime: expectation,
                    applicationPayload: payload,
                    attestationTimeout: timeout
                )
                Issue.record("expected invalidAttestationTimeout")
            } catch let error as CodexSyntheticInteractiveTransportError {
                #expect(error == .invalidAttestationTimeout)
            }
        }

        #expect(await transcript.factoryOpenCount == 0)
        #expect(await transcript.writes.isEmpty)
    }

    @Test("request timeoutはsealed payload budgetからだけ導出する")
    func requestTimeoutIsDerivedFromSealedBudget() throws {
        let payload = try syntheticInteractivePayload(timeoutSeconds: 7)

        let request = try syntheticInteractiveRequest(applicationPayload: payload)

        #expect(request.requestTimeout == .seconds(7))
        #expect(request.requestTimeout == .seconds(payload.budget.timeoutSeconds))
    }
}
