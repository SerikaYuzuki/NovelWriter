import Foundation
@testable import FUMINIWAExperimental
import Testing

@Suite("Codex synthetic interactive rejection", .serialized)
struct CodexSyntheticRejectionTests {
    @Test("empty read chunkはbusy loopせず1回でfail closedする")
    func emptyReadChunkFailsClosed() async throws {
        let harness = syntheticInteractiveHarness(
            readSteps: [.bytes(Data()), .endOfFile]
        )

        let error = await capturedSyntheticInteractiveError {
            _ = try await harness.transport.run(syntheticInteractiveRequest())
        }

        #expect(error != nil)
        #expect(await harness.transcript.readCount == 1)
        #expect(try await harness.transcript.startWriteCount() == 0)
        #expect(await harness.transcript.cleanupCount == 1)
    }

    @Test("duplicate terminalはEOFまでのdrain中に拒否する")
    func duplicateTerminalIsRejected() async throws {
        let harness = try syntheticInteractiveHarness(
            readSteps: [
                .bytes(syntheticReadyFrame()),
                .bytes(syntheticStartedFrame()),
                .bytes(syntheticCompletedFrame()),
                .bytes(syntheticFailedFrame()),
                .endOfFile
            ]
        )

        let error = await capturedSyntheticInteractiveError {
            _ = try await harness.transport.run(syntheticInteractiveRequest())
        }

        #expect(error == .protocolFailure(.duplicateTerminal))
        #expect(await harness.transcript.cleanupCount == 1)
    }

    @Test("terminal後のlate startedはEOF前に拒否する")
    func lateStartedAfterTerminalIsRejected() async throws {
        let harness = try syntheticInteractiveHarness(
            readSteps: [
                .bytes(syntheticReadyFrame()),
                .bytes(syntheticStartedFrame()),
                .bytes(syntheticCompletedFrame()),
                .bytes(syntheticStartedFrame()),
                .endOfFile
            ]
        )

        let error = await capturedSyntheticInteractiveError {
            _ = try await harness.transport.run(syntheticInteractiveRequest())
        }

        #expect(error == .protocolFailure(.eventAfterTerminal))
    }

    @Test("terminal後のpartial frame EOFは成功を返さない")
    func partialFrameAfterTerminalIsRejectedAtEOF() async throws {
        let harness = try syntheticInteractiveHarness(
            readSteps: [
                .bytes(syntheticReadyFrame()),
                .bytes(syntheticStartedFrame()),
                .bytes(syntheticCompletedFrame()),
                .bytes(Data(#"{"version":1"#.utf8)),
                .endOfFile
            ]
        )

        let error = await capturedSyntheticInteractiveError {
            _ = try await harness.transport.run(syntheticInteractiveRequest())
        }

        #expect(error == .protocolFailure(.unterminatedFrame))
        #expect(await harness.transcript.cleanupCount == 1)
    }

    @Test("attestation frame cap超過はstart 0で拒否する")
    func frameLimitExceededBeforeReadyWritesNoStart() async throws {
        let oversized = Data(
            repeating: 0x41,
            count: CodexSidecarFrameDecoder.maximumFrameBytes + 1
        )
        let harness = syntheticInteractiveHarness(
            readSteps: [.bytes(oversized), .endOfFile]
        )

        let error = await capturedSyntheticInteractiveError {
            _ = try await harness.transport.run(syntheticInteractiveRequest())
        }

        #expect(
            error == .protocolFailure(
                .frameTooLarge(
                    limit: CodexSidecarFrameDecoder.maximumFrameBytes,
                    actual: oversized.count
                )
            )
        )
        #expect(try await harness.transcript.startWriteCount() == 0)
    }

    @Test("stdout cumulative stream capはframe decodeより先にfail closedする")
    func cumulativeStreamLimitIsEnforced() async throws {
        let ready = try syntheticReadyFrame()
        let started = try syntheticStartedFrame()
        let outputLength = CodexSidecarFrameDecoder.maximumFrameBytes - 1024
        let completed = try syntheticCompletedFrame(
            structuredOutput: String(repeating: "a", count: outputLength)
        )
        var coalesced = completed
        coalesced.append(completed)
        for _ in 0 ..< 32 {
            try coalesced.append(syntheticFailedFrame())
        }
        let actual = ready.count + started.count + coalesced.count
        #expect(actual > CodexSidecarFrameDecoder.maximumStreamBytes)
        let harness = syntheticInteractiveHarness(
            readSteps: [
                .bytes(ready),
                .bytes(started),
                .bytes(coalesced)
            ]
        )

        let error = await capturedSyntheticInteractiveError {
            _ = try await harness.transport.run(syntheticInteractiveRequest())
        }

        #expect(
            error == .protocolFailure(
                .streamByteLimitExceeded(
                    limit: CodexSidecarFrameDecoder.maximumStreamBytes,
                    actual: actual
                )
            )
        )
        #expect(await harness.transcript.cleanupCount == 1)
    }

    @Test("malformed frameのraw contentはtyped errorへ保持しない")
    func malformedFrameDoesNotLeakContent() async throws {
        let rawContent = Data(
            "raw-secret=synthetic-api-key path=/private/secret/manuscript.novelpkg\n".utf8
        )
        let harness = syntheticInteractiveHarness(
            readSteps: [.bytes(rawContent), .endOfFile]
        )

        let error = await capturedSyntheticInteractiveError {
            _ = try await harness.transport.run(syntheticInteractiveRequest())
        }

        let typedError = try #require(error)
        #expect(typedError == .protocolFailure(.malformedJSON))
        expectNoRawSyntheticErrorDisclosure(typedError)
    }
}
