import Foundation
@testable import FUMINIWAExperimental
import Testing

@Suite("Codex synthetic interactive attestation", .serialized)
struct CodexSyntheticAttestationTests {
    @Test("ready request ID不一致はstart 0でfail closedする")
    func wrongReadyRequestIDWritesNoStart() async throws {
        let harness = try syntheticInteractiveHarness(
            readSteps: [
                .bytes(syntheticReadyFrame(requestID: otherProtocolRequestID)),
                .endOfFile
            ]
        )

        let error = await capturedSyntheticInteractiveError {
            _ = try await harness.transport.run(syntheticInteractiveRequest())
        }

        #expect(error == .protocolFailure(.wrongRequestID))
        #expect(try await harness.transcript.startWriteCount() == 0)
        #expect(await harness.transcript.cleanupCount == 1)
    }

    @Test("ready runtime不一致はstart 0でfail closedする")
    func wrongReadyRuntimeWritesNoStart() async throws {
        let driftedRuntime = try CodexSidecarRuntimeIdentity(
            mode: .mock,
            sidecarVersion: "drifted",
            sidecarBundleSHA256: nil,
            nodeVersion: "0.0.0-test",
            nodeSHA256: nil,
            architecture: .arm64,
            sdkVersion: nil,
            sdkIntegrity: nil,
            cliVersion: nil,
            cliSHA256: nil
        )
        let harness = try syntheticInteractiveHarness(
            readSteps: [
                .bytes(syntheticReadyFrame(runtime: driftedRuntime)),
                .endOfFile
            ]
        )

        let error = await capturedSyntheticInteractiveError {
            _ = try await harness.transport.run(syntheticInteractiveRequest())
        }

        #expect(error == .protocolFailure(.runtimeIdentityMismatch))
        #expect(try await harness.transcript.startWriteCount() == 0)
    }

    @Test("readyのextra fieldはstart 0でfail closedする")
    func readyWithExtraFieldWritesNoStart() async throws {
        let harness = syntheticInteractiveHarness(
            readSteps: [
                .bytes(syntheticInvalidReadyFrame(extraMember: "secret")),
                .endOfFile
            ]
        )

        let error = await capturedSyntheticInteractiveError {
            _ = try await harness.transport.run(syntheticInteractiveRequest())
        }

        #expect(error == .protocolFailure(.unexpectedFields))
        #expect(try await harness.transcript.startWriteCount() == 0)
    }

    @Test("readyと次eventのcoalesced chunkはstartを書かず拒否する")
    func coalescedReadyAndEventWritesNoStart() async throws {
        var coalesced = try syntheticReadyFrame()
        try coalesced.append(syntheticStartedFrame())
        let harness = syntheticInteractiveHarness(
            readSteps: [.bytes(coalesced), .endOfFile]
        )

        let error = await capturedSyntheticInteractiveError {
            _ = try await harness.transport.run(syntheticInteractiveRequest())
        }

        #expect(error == .attestationFrameNotIsolated)
        #expect(try await harness.transcript.startWriteCount() == 0)
    }

    @Test("ready後のpartial trailing frameもstartを書かず拒否する")
    func readyWithPartialTrailingFrameWritesNoStart() async throws {
        var bytes = try syntheticReadyFrame()
        bytes.append(Data(#"{"version":1"#.utf8))
        let harness = syntheticInteractiveHarness(
            readSteps: [.bytes(bytes), .endOfFile]
        )

        let error = await capturedSyntheticInteractiveError {
            _ = try await harness.transport.run(syntheticInteractiveRequest())
        }

        #expect(error == .attestationFrameNotIsolated)
        #expect(try await harness.transcript.startWriteCount() == 0)
    }

    @Test("partial readyがEOFになればstartを書かない")
    func partialReadyAtEOFWritesNoStart() async throws {
        let ready = try syntheticReadyFrame()
        let harness = syntheticInteractiveHarness(
            readSteps: [
                .bytes(Data(ready.prefix(ready.count / 2))),
                .endOfFile
            ]
        )

        let error = await capturedSyntheticInteractiveError {
            _ = try await harness.transport.run(syntheticInteractiveRequest())
        }

        #expect(error != nil)
        #expect(try await harness.transcript.startWriteCount() == 0)
    }
}
