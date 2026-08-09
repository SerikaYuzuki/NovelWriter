import Foundation
@testable import FUMINIWAExperimental
import Testing

@Suite("Codex synthetic interactive redaction", .serialized)
struct CodexSyntheticRedactionTests {
    @Test("factory raw errorは固定channelOpenFailedへredactしtransport cleanupしない")
    func factoryErrorIsRedactedAndFactoryOwnsPartialCleanup() async throws {
        let harness = syntheticInteractiveHarness(
            readSteps: [],
            factoryFailure: .secret
        )

        let error = await capturedSyntheticInteractiveError {
            _ = try await harness.transport.run(syntheticInteractiveRequest())
        }

        let typedError = try #require(error)
        #expect(typedError == .channelOpenFailed)
        expectNoRawSyntheticErrorDisclosure(typedError)
        #expect(await harness.transcript.factoryOpenCount == 1)
        #expect(await harness.transcript.cleanupCount == 0)
    }

    @Test("factory open cancellation raw errorはcleanupFailedへredactする")
    func factoryCancellationErrorIsRedacted() async throws {
        let gate = SyntheticInteractiveGate()
        let harness = syntheticInteractiveHarness(
            readSteps: [],
            factoryGate: gate,
            factoryCancellationFailure: .secret
        )
        let task = Task {
            try await harness.transport.run(syntheticInteractiveRequest())
        }
        await waitForSyntheticFactoryOpens(1, transcript: harness.transcript)

        await harness.transport.cancel()
        let error = await capturedSyntheticInteractiveError {
            _ = try await task.value
        }

        let typedError = try #require(error)
        #expect(typedError == .cleanupFailed)
        expectNoRawSyntheticErrorDisclosure(typedError)
        #expect(await harness.transcript.factoryCancellationCount == 1)
        #expect(await harness.transcript.cleanupCount == 1)
    }

    @Test("hello write raw errorはoperation分類だけを返してcleanupする")
    func helloWriteErrorIsRedacted() async throws {
        let harness = syntheticInteractiveHarness(
            readSteps: [],
            writeSteps: [.failure(.secret)]
        )

        let error = await capturedSyntheticInteractiveError {
            _ = try await harness.transport.run(syntheticInteractiveRequest())
        }

        let typedError = try #require(error)
        #expect(typedError == .channelIOFailed(.writeHello))
        expectNoRawSyntheticErrorDisclosure(typedError)
        #expect(await harness.transcript.cleanupCount == 1)
    }

    @Test("attestation read raw errorはoperation分類だけを返す")
    func attestationReadErrorIsRedacted() async throws {
        let harness = syntheticInteractiveHarness(
            readSteps: [.failure(.secret)]
        )

        let error = await capturedSyntheticInteractiveError {
            _ = try await harness.transport.run(syntheticInteractiveRequest())
        }

        let typedError = try #require(error)
        #expect(typedError == .channelIOFailed(.readAttestation))
        expectNoRawSyntheticErrorDisclosure(typedError)
        #expect(try await harness.transcript.startWriteCount() == 0)
    }

    @Test("start write raw errorはoperation分類だけを返す")
    func startWriteErrorIsRedacted() async throws {
        let harness = try syntheticInteractiveHarness(
            readSteps: [.bytes(syntheticReadyFrame())],
            writeSteps: [.succeed, .failure(.secret)]
        )

        let error = await capturedSyntheticInteractiveError {
            _ = try await harness.transport.run(syntheticInteractiveRequest())
        }

        let typedError = try #require(error)
        #expect(typedError == .channelIOFailed(.writeStart))
        expectNoRawSyntheticErrorDisclosure(typedError)
        #expect(try await harness.transcript.startWriteCount() == 1)
        #expect(await harness.transcript.cleanupCount == 1)
    }

    @Test("response read raw errorはoperation分類だけを返す")
    func responseReadErrorIsRedacted() async throws {
        let harness = try syntheticInteractiveHarness(
            readSteps: [
                .bytes(syntheticReadyFrame()),
                .failure(.secret)
            ]
        )

        let error = await capturedSyntheticInteractiveError {
            _ = try await harness.transport.run(syntheticInteractiveRequest())
        }

        let typedError = try #require(error)
        #expect(typedError == .channelIOFailed(.readResponse))
        expectNoRawSyntheticErrorDisclosure(typedError)
        #expect(await harness.transcript.cleanupCount == 1)
    }

    @Test("requestCancellation raw errorは固定operationへredactする")
    func cancellationRequestErrorIsRedacted() async throws {
        let gate = SyntheticInteractiveGate()
        let harness = syntheticInteractiveHarness(
            readSteps: [.blocked(gate: gate, result: .endOfFile)],
            cancellationFailure: .secret
        )
        let task = Task {
            try await harness.transport.run(syntheticInteractiveRequest())
        }
        await waitForSyntheticReads(1, transcript: harness.transcript)

        await harness.transport.cancel()
        let error = await capturedSyntheticInteractiveError {
            _ = try await task.value
        }

        let typedError = try #require(error)
        #expect(typedError == .channelIOFailed(.requestCancellation))
        expectNoRawSyntheticErrorDisclosure(typedError)
        #expect(await harness.transcript.cleanupCount == 1)
    }

    @Test("cleanup raw errorはsuccess terminalより優先して固定cleanupFailedを返す")
    func cleanupErrorOverridesSuccessAndIsRedacted() async throws {
        let harness = try syntheticInteractiveHarness(
            readSteps: [
                .bytes(syntheticReadyFrame()),
                .bytes(syntheticStartedFrame()),
                .bytes(syntheticCompletedFrame()),
                .endOfFile
            ],
            cleanupFailure: .secret
        )

        let error = await capturedSyntheticInteractiveError {
            _ = try await harness.transport.run(syntheticInteractiveRequest())
        }

        let typedError = try #require(error)
        #expect(typedError == .cleanupFailed)
        expectNoRawSyntheticErrorDisclosure(typedError)
    }

    @Test("cleanup failureは先行protocol/read failureより優先する")
    func cleanupErrorOverridesPrimaryFailure() async {
        let harness = syntheticInteractiveHarness(
            readSteps: [.failure(.secret)],
            cleanupFailure: .secret
        )

        let error = await capturedSyntheticInteractiveError {
            _ = try await harness.transport.run(syntheticInteractiveRequest())
        }

        #expect(error == .cleanupFailed)
    }
}
