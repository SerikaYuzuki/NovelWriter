import Foundation
@testable import FUMINIWAExperimental
import Testing

// Lifecycle races are kept in one serialized suite to share one state-machine vocabulary.
// swiftlint:disable file_length

@Suite("Codex synthetic interactive lifecycle", .serialized)
// swiftlint:disable:next type_body_length
struct CodexSyntheticLifecycleTests {
    @Test("cooperative factory openは明示cancelだけで中断しchannelを返さない")
    func cooperativeFactoryOpenStopsWithoutManualRelease() async {
        let transcript = SyntheticInteractiveTranscript()
        let channel = SyntheticInteractiveChannel(transcript: transcript, readSteps: [])
        let factory = SyntheticCooperativeFactory(
            transcript: transcript,
            channel: channel
        )
        let transport = CodexSyntheticInteractiveTransport(factory: factory)
        let task = Task {
            try await transport.run(syntheticInteractiveRequest())
        }
        await waitForSyntheticFactoryOpens(1, transcript: transcript)

        await transport.cancel()
        let error = await capturedSyntheticInteractiveError {
            _ = try await task.value
        }

        #expect(error == .cancelled)
        #expect(await transcript.writes.isEmpty)
        #expect(await transcript.cleanupCount == 0)
        #expect(await transcript.factoryCancellationCount == 1)
    }

    @Test("timeout後にfactoryがlate channelを返せばhello前にcleanupする")
    func lateFactoryResultAfterTimeoutIsCleanedUp() async {
        let transcript = SyntheticInteractiveTranscript()
        let channel = SyntheticInteractiveChannel(transcript: transcript, readSteps: [])
        let factory = SyntheticInteractiveLateReturningFactory(
            transcript: transcript,
            channel: channel,
            delay: .milliseconds(80)
        )
        let transport = CodexSyntheticInteractiveTransport(factory: factory)

        let error = await capturedSyntheticInteractiveError {
            _ = try await transport.run(
                syntheticInteractiveRequest(attestationTimeout: .milliseconds(20))
            )
        }
        await waitForSyntheticCleanups(1, transcript: transcript)

        #expect(error == .attestationTimedOut)
        #expect(await transcript.writes.isEmpty)
        #expect(await transcript.cleanupCount == 1)
        #expect(await transcript.factoryCancellationCount == 1)
    }

    @Test("late factory channelのcleanup failureはtimeoutより優先する")
    func lateFactoryCleanupFailureOverridesTimeout() async {
        let transcript = SyntheticInteractiveTranscript()
        let channel = SyntheticInteractiveChannel(
            transcript: transcript,
            readSteps: [],
            cleanupFailure: .secret
        )
        let factory = SyntheticInteractiveLateReturningFactory(
            transcript: transcript,
            channel: channel,
            delay: .milliseconds(80)
        )
        let transport = CodexSyntheticInteractiveTransport(factory: factory)

        let error = await capturedSyntheticInteractiveError {
            _ = try await transport.run(
                syntheticInteractiveRequest(attestationTimeout: .milliseconds(20))
            )
        }

        #expect(error == .cleanupFailed)
        #expect(await transcript.cleanupCount == 1)
        #expect(await transcript.factoryCancellationCount == 1)
    }

    @Test("factory open中のconsumer cancelはhello/start 0でcleanupする")
    func cancellationDuringFactoryOpenWritesNothing() async {
        let gate = SyntheticInteractiveGate()
        let harness = syntheticInteractiveHarness(
            readSteps: [],
            factoryGate: gate
        )
        let task = Task {
            try await harness.transport.run(syntheticInteractiveRequest())
        }
        await waitForSyntheticFactoryOpens(1, transcript: harness.transcript)

        await harness.transport.cancel()
        let error = await capturedSyntheticInteractiveError {
            _ = try await task.value
        }

        #expect(error == .cancelled)
        #expect(await harness.transcript.writes.isEmpty)
        #expect(await harness.transcript.cleanupCount == 1)
        #expect(await harness.transcript.factoryCancellationCount == 1)
    }

    @Test("ready待ちのcancelはwire start/cancel 0でpending readを解除する")
    func cancellationBeforeReadyWritesNoContentOrWireCancel() async throws {
        let gate = SyntheticInteractiveGate()
        let harness = syntheticInteractiveHarness(
            readSteps: [.blocked(gate: gate, result: .endOfFile)]
        )
        let task = Task {
            try await harness.transport.run(syntheticInteractiveRequest())
        }
        await waitForSyntheticReads(1, transcript: harness.transcript)

        await harness.transport.cancel()
        let error = await capturedSyntheticInteractiveError {
            _ = try await task.value
        }

        #expect(error == .cancelled)
        #expect(try await harness.transcript.startWriteCount() == 0)
        #expect(try await harness.transcript.cancelWriteCount() == 0)
        #expect(await harness.transcript.cancellationCount == 1)
        #expect(await harness.transcript.cleanupCount == 1)
    }

    @Test("Task.cancelでchannel readが先にCancellationErrorでもcancelledへ固定する")
    func taskCancellationWinsChannelCancellationErrorRace() async throws {
        let harness = syntheticInteractiveHarness(
            readSteps: [.waitForTaskCancellation]
        )
        let task = Task {
            try await harness.transport.run(syntheticInteractiveRequest())
        }
        await waitForSyntheticReads(1, transcript: harness.transcript)

        task.cancel()
        let error = await capturedSyntheticInteractiveError {
            _ = try await task.value
        }

        #expect(error == .cancelled)
        #expect(try await harness.transcript.startWriteCount() == 0)
        #expect(await harness.transcript.cleanupCount == 1)
    }

    @Test("cancelで解除されたreadがvalid readyを返してもcancelがfirst-wins")
    func cancellationWinsOverReadyReturnedByUnblockedRead() async throws {
        let gate = SyntheticInteractiveGate()
        let harness = try syntheticInteractiveHarness(
            readSteps: [
                .blocked(gate: gate, result: .bytes(syntheticReadyFrame()))
            ]
        )
        let task = Task {
            try await harness.transport.run(syntheticInteractiveRequest())
        }
        await waitForSyntheticReads(1, transcript: harness.transcript)

        await harness.transport.cancel()
        let error = await capturedSyntheticInteractiveError {
            _ = try await task.value
        }

        #expect(error == .cancelled)
        #expect(try await harness.transcript.startWriteCount() == 0)
        #expect(await harness.transcript.cleanupCount == 1)
    }

    @Test("start後のduplicate cancelはwire cancelとchannel cancellationが最大1回")
    func duplicateCancellationAfterStartIsAtMostOnce() async throws {
        let gate = SyntheticInteractiveGate()
        let harness = try syntheticInteractiveHarness(
            readSteps: [
                .bytes(syntheticReadyFrame()),
                .blocked(gate: gate, result: .endOfFile)
            ]
        )
        let task = Task {
            try await harness.transport.run(syntheticInteractiveRequest())
        }
        await waitForSyntheticWrites(2, transcript: harness.transcript)
        await waitForSyntheticReads(2, transcript: harness.transcript)

        async let firstCancel: Void = harness.transport.cancel()
        async let secondCancel: Void = harness.transport.cancel()
        _ = await (firstCancel, secondCancel)
        let error = await capturedSyntheticInteractiveError {
            _ = try await task.value
        }

        #expect(error == .cancelled)
        #expect(try await harness.transcript.startWriteCount() == 1)
        #expect(try await harness.transcript.cancelWriteCount() == 1)
        #expect(await harness.transcript.cancellationCount == 1)
        #expect(await harness.transcript.cleanupCount == 1)
    }

    @Test("cancel frame writeがblockedでもchannel cancellation hookが解除する")
    func cancellationHookUnblocksCancelFrameWrite() async throws {
        let readGate = SyntheticInteractiveGate()
        let cancelWriteGate = SyntheticInteractiveGate()
        let harness = try syntheticInteractiveHarness(
            readSteps: [
                .bytes(syntheticReadyFrame()),
                .bytes(syntheticStartedFrame()),
                .blocked(gate: readGate, result: .endOfFile)
            ],
            writeSteps: [
                .succeed,
                .succeed
            ],
            cancellationWriteStep: .blocked(
                gate: cancelWriteGate,
                result: .succeed
            )
        )
        let task = Task {
            try await harness.transport.run(syntheticInteractiveRequest())
        }
        await waitForSyntheticReads(3, transcript: harness.transcript)

        await harness.transport.cancel()
        let error = await capturedSyntheticInteractiveError {
            _ = try await task.value
        }

        #expect(error == .cancelled)
        #expect(await harness.transcript.cancellationCount == 1)
        #expect(try await harness.transcript.cancelWriteCount() == 1)
        #expect(await harness.transcript.cleanupCount == 1)
    }

    @Test("cancelで解除されたreadがcompletedを返してもresultをdeliveryしない")
    func cancellationWinsOverTerminalReturnedByUnblockedRead() async throws {
        let gate = SyntheticInteractiveGate()
        let harness = try syntheticInteractiveHarness(
            readSteps: [
                .bytes(syntheticReadyFrame()),
                .bytes(syntheticStartedFrame()),
                .blocked(gate: gate, result: .bytes(syntheticCompletedFrame()))
            ]
        )
        let task = Task {
            try await harness.transport.run(syntheticInteractiveRequest())
        }
        await waitForSyntheticReads(3, transcript: harness.transcript)

        await harness.transport.cancel()
        let error = await capturedSyntheticInteractiveError {
            _ = try await task.value
        }

        #expect(error == .cancelled)
        #expect(try await harness.transcript.startWriteCount() == 1)
        #expect(try await harness.transcript.cancelWriteCount() == 1)
        #expect(await harness.transcript.cancellationCount == 1)
    }

    @Test("terminal受理後のEOF待ちcancelはresultを返さずwire cancel 0")
    func cancellationAfterTerminalSuppressesResult() async throws {
        let gate = SyntheticInteractiveGate()
        let harness = try syntheticInteractiveHarness(
            readSteps: [
                .bytes(syntheticReadyFrame()),
                .bytes(syntheticStartedFrame()),
                .bytes(syntheticCompletedFrame()),
                .blocked(gate: gate, result: .endOfFile)
            ]
        )
        let task = Task {
            try await harness.transport.run(syntheticInteractiveRequest())
        }
        await waitForSyntheticReads(4, transcript: harness.transcript)

        await harness.transport.cancel()
        let error = await capturedSyntheticInteractiveError {
            _ = try await task.value
        }

        #expect(error == .cancelled)
        #expect(try await harness.transcript.startWriteCount() == 1)
        #expect(try await harness.transcript.cancelWriteCount() == 0)
        #expect(await harness.transcript.cancellationCount == 1)
    }

    @Test("attestation timeoutはstart 0でpending readを解除してcleanupする")
    func attestationTimeoutWritesNoStart() async throws {
        let gate = SyntheticInteractiveGate()
        let harness = syntheticInteractiveHarness(
            readSteps: [.blocked(gate: gate, result: .endOfFile)]
        )

        let error = await capturedSyntheticInteractiveError {
            _ = try await harness.transport.run(
                syntheticInteractiveRequest(attestationTimeout: .milliseconds(20))
            )
        }

        #expect(error == .attestationTimedOut)
        #expect(try await harness.transcript.startWriteCount() == 0)
        #expect(await harness.transcript.cancellationCount == 1)
        #expect(await harness.transcript.cleanupCount == 1)
    }

    @Test("exact ready受理後はattestation deadline超過中のstartを逆転させない")
    func acceptedReadyCancelsAttestationDeadline() async throws {
        let startWriteGate = SyntheticInteractiveGate()
        let harness = try syntheticInteractiveHarness(
            readSteps: [
                .bytes(syntheticReadyFrame()),
                .bytes(syntheticStartedFrame()),
                .bytes(syntheticFailedFrame()),
                .endOfFile
            ],
            writeSteps: [
                .succeed,
                .blocked(gate: startWriteGate, result: .succeed)
            ]
        )
        let releaseTask = Task {
            try? await Task.sleep(for: .milliseconds(80))
            await startWriteGate.open()
        }
        defer { releaseTask.cancel() }

        let terminal = try await harness.transport.run(
            syntheticInteractiveRequest(attestationTimeout: .milliseconds(20))
        )

        #expect(terminal == .failed(.providerUnavailable))
        #expect(await harness.transcript.cancellationCount == 0)
        #expect(await harness.transcript.cleanupCount == 1)
    }

    @Test("sealed request timeoutはstart後のpending readをcancelしてcleanupする")
    func requestTimeoutCancelsStartedRequest() async throws {
        let gate = SyntheticInteractiveGate()
        let payload = try syntheticInteractivePayload(timeoutSeconds: 1)
        let harness = try syntheticInteractiveHarness(
            readSteps: [
                .bytes(syntheticReadyFrame()),
                .bytes(syntheticStartedFrame()),
                .blocked(gate: gate, result: .endOfFile)
            ]
        )

        let error = await capturedSyntheticInteractiveError {
            _ = try await harness.transport.run(
                syntheticInteractiveRequest(applicationPayload: payload)
            )
        }

        #expect(error == .requestTimedOut)
        #expect(try await harness.transcript.startWriteCount() == 1)
        #expect(try await harness.transcript.cancelWriteCount() == 1)
        #expect(await harness.transcript.cancellationCount == 1)
        #expect(await harness.transcript.cleanupCount == 1)
    }

    @Test("attestation遅延はsealed requestのabsolute deadlineを延長しない")
    func attestationDelayDoesNotExtendRequestDeadline() async throws {
        let attestationGate = SyntheticInteractiveGate()
        let responseGate = SyntheticInteractiveGate()
        let payload = try syntheticInteractivePayload(timeoutSeconds: 1)
        let harness = try syntheticInteractiveHarness(
            readSteps: [
                .blocked(gate: attestationGate, result: .bytes(syntheticReadyFrame())),
                .bytes(syntheticStartedFrame()),
                .blocked(gate: responseGate, result: .endOfFile)
            ]
        )
        let releaseTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            await attestationGate.open()
        }
        defer { releaseTask.cancel() }
        let clock = ContinuousClock()
        let start = clock.now

        let error = await capturedSyntheticInteractiveError {
            _ = try await harness.transport.run(
                syntheticInteractiveRequest(
                    applicationPayload: payload,
                    attestationTimeout: .seconds(2)
                )
            )
        }
        let elapsed = start.duration(to: clock.now)

        #expect(error == .requestTimedOut)
        #expect(elapsed >= .milliseconds(800))
        #expect(elapsed < .milliseconds(1400))
        #expect(try await harness.transcript.startWriteCount() == 1)
        #expect(await harness.transcript.cleanupCount == 1)
    }

    @Test("deadline前terminalはdeadline後EOFでもfixed drain内なら成功する")
    func terminalClaimsBeforeDeadlineAndSurvivesLateEOF() async throws {
        let terminalGate = SyntheticInteractiveGate()
        let eofGate = SyntheticInteractiveGate()
        let payload = try syntheticInteractivePayload(timeoutSeconds: 1)
        let expectedOutput = #"{"replacement":"synthetic","summary":"test","warnings":[]}"#
        let harness = try syntheticInteractiveHarness(
            readSteps: [
                .bytes(syntheticReadyFrame()),
                .bytes(syntheticStartedFrame()),
                .blocked(
                    gate: terminalGate,
                    result: .bytes(syntheticCompletedFrame(
                        structuredOutput: expectedOutput
                    ))
                ),
                .blocked(gate: eofGate, result: .endOfFile)
            ]
        )
        let terminalRelease = Task {
            try? await Task.sleep(for: .milliseconds(700))
            await terminalGate.open()
        }
        let eofRelease = Task {
            try? await Task.sleep(for: .milliseconds(1200))
            await eofGate.open()
        }
        defer {
            terminalRelease.cancel()
            eofRelease.cancel()
        }

        let terminal = try await harness.transport.run(
            syntheticInteractiveRequest(applicationPayload: payload)
        )

        #expect(
            try terminal == .completed(
                structuredOutput: expectedOutput,
                usage: CodexSidecarUsage(inputTokens: 1, outputTokens: 1)
            )
        )
        #expect(await harness.transcript.cancellationCount == 0)
        #expect(await harness.transcript.cleanupCount == 1)
    }

    @Test("terminal後EOFなしはfixed drain timeoutでresultを返さない")
    func missingEOFAfterTerminalTimesOutDrain() async throws {
        let eofGate = SyntheticInteractiveGate()
        let harness = try syntheticInteractiveHarness(
            readSteps: [
                .bytes(syntheticReadyFrame()),
                .bytes(syntheticStartedFrame()),
                .bytes(syntheticCompletedFrame()),
                .blocked(gate: eofGate, result: .endOfFile)
            ]
        )

        let error = await capturedSyntheticInteractiveError {
            _ = try await harness.transport.run(syntheticInteractiveRequest())
        }

        #expect(error == .terminalDrainTimedOut)
        #expect(
            CodexSyntheticInteractiveTransportRequest.terminalDrainTimeout == .seconds(1)
        )
        #expect(await harness.transcript.cancellationCount == 1)
        #expect(await harness.transcript.cleanupCount == 1)
    }

    @Test("EOFはready前・started前・terminal前の各phaseでfail closedする")
    func prematureEOFAtEachPhaseFailsClosed() async throws {
        let scenarios: [([SyntheticInteractiveReadStep], Int)] = try [
            ([.endOfFile], 0),
            ([.bytes(syntheticReadyFrame()), .endOfFile], 1),
            ([
                .bytes(syntheticReadyFrame()),
                .bytes(syntheticStartedFrame()),
                .endOfFile
            ], 1)
        ]

        for (readSteps, expectedStartCount) in scenarios {
            let harness = syntheticInteractiveHarness(readSteps: readSteps)
            let error = await capturedSyntheticInteractiveError {
                _ = try await harness.transport.run(syntheticInteractiveRequest())
            }

            #expect(error == .protocolFailure(.unexpectedEOF))
            #expect(try await harness.transcript.startWriteCount() == expectedStartCount)
            #expect(await harness.transcript.cleanupCount == 1)
        }
    }

    @Test("同じtransportの並行2件目はfactoryを再openせずalreadyRunning")
    func concurrentSecondRunIsRejected() async {
        let gate = SyntheticInteractiveGate()
        let harness = syntheticInteractiveHarness(
            readSteps: [.blocked(gate: gate, result: .endOfFile)]
        )
        let firstTask = Task {
            try await harness.transport.run(syntheticInteractiveRequest())
        }
        await waitForSyntheticReads(1, transcript: harness.transcript)

        let secondError = await capturedSyntheticInteractiveError {
            _ = try await harness.transport.run(syntheticInteractiveRequest())
        }

        #expect(secondError == .alreadyRunning)
        #expect(await harness.transcript.factoryOpenCount == 1)
        await harness.transport.cancel()
        _ = await capturedSyntheticInteractiveError {
            _ = try await firstTask.value
        }
    }

    @Test("sequential runは毎回factoryから新しいcontent-free channelを得る")
    func sequentialRunsOpenFreshChannels() async throws {
        let transcript = SyntheticInteractiveTranscript()
        let firstChannel = try SyntheticInteractiveChannel(
            transcript: transcript,
            readSteps: [
                .bytes(syntheticReadyFrame()),
                .bytes(syntheticStartedFrame()),
                .bytes(syntheticFailedFrame(code: .providerUnavailable)),
                .endOfFile
            ]
        )
        let secondChannel = try SyntheticInteractiveChannel(
            transcript: transcript,
            readSteps: [
                .bytes(syntheticReadyFrame(requestID: otherProtocolRequestID)),
                .bytes(syntheticStartedFrame(requestID: otherProtocolRequestID)),
                .bytes(syntheticFailedFrame(
                    requestID: otherProtocolRequestID,
                    code: .offline
                )),
                .endOfFile
            ]
        )
        let factory = SyntheticInteractiveSequenceFactory(
            transcript: transcript,
            results: [.channel(firstChannel), .channel(secondChannel)]
        )
        let transport = CodexSyntheticInteractiveTransport(factory: factory)

        let first = try await transport.run(syntheticInteractiveRequest())
        let second = try await transport.run(
            syntheticInteractiveRequest(requestID: otherProtocolRequestID)
        )

        #expect(first == .failed(.providerUnavailable))
        #expect(second == .failed(.offline))
        #expect(await transcript.factoryOpenCount == 2)
        #expect(try await transcript.startWriteCount() == 2)
        #expect(await transcript.cleanupCount == 2)
    }

    @Test("factoryが同じchannel instanceを再利用すると2回目hello前に拒否する")
    func sequentialReuseOfSameChannelIsRejected() async throws {
        let transcript = SyntheticInteractiveTranscript()
        let channel = try SyntheticInteractiveChannel(
            transcript: transcript,
            readSteps: [
                .bytes(syntheticReadyFrame()),
                .bytes(syntheticStartedFrame()),
                .bytes(syntheticFailedFrame()),
                .endOfFile
            ]
        )
        let factory = SyntheticInteractiveSequenceFactory(
            transcript: transcript,
            results: [.channel(channel), .channel(channel)]
        )
        let transport = CodexSyntheticInteractiveTransport(factory: factory)
        _ = try await transport.run(syntheticInteractiveRequest())
        let writesAfterFirstRun = await transcript.writes.count

        let error = await capturedSyntheticInteractiveError {
            _ = try await transport.run(syntheticInteractiveRequest())
        }

        #expect(error == .reusedChannel)
        #expect(await transcript.factoryOpenCount == 2)
        #expect(await transcript.writes.count == writesAfterFirstRun)
        #expect(try await transcript.startWriteCount() == 1)
        #expect(await transcript.cleanupCount == 1)
    }

    @Test("別transportのlive channel再利用拒否は先行ownerをcleanupしない")
    func liveChannelReuseAcrossTransportsIsRejected() async throws {
        let transcript = SyntheticInteractiveTranscript()
        let firstReadGate = SyntheticInteractiveGate()
        let channel = try SyntheticInteractiveChannel(
            transcript: transcript,
            readSteps: [
                .bytes(syntheticReadyFrame()),
                .bytes(syntheticStartedFrame()),
                .blocked(gate: firstReadGate, result: .endOfFile)
            ]
        )
        let factory = SyntheticInteractiveSequenceFactory(
            transcript: transcript,
            results: [.channel(channel), .channel(channel)]
        )
        let firstTransport = CodexSyntheticInteractiveTransport(factory: factory)
        let secondTransport = CodexSyntheticInteractiveTransport(factory: factory)
        let firstTask = Task {
            try await firstTransport.run(syntheticInteractiveRequest())
        }
        await waitForSyntheticReads(3, transcript: transcript)
        let writesBeforeReuse = await transcript.writes.count
        let readsBeforeReuse = await transcript.readCount

        let error = await capturedSyntheticInteractiveError {
            _ = try await secondTransport.run(syntheticInteractiveRequest())
        }

        #expect(error == .reusedChannel)
        #expect(await transcript.factoryOpenCount == 2)
        #expect(await transcript.writes.count == writesBeforeReuse)
        #expect(await transcript.readCount == readsBeforeReuse)
        #expect(try await transcript.startWriteCount() == 1)
        #expect(await transcript.cleanupCount == 0)

        await firstTransport.cancel()
        let firstError = await capturedSyntheticInteractiveError {
            _ = try await firstTask.value
        }
        #expect(firstError == .cancelled)
        #expect(await transcript.cancellationCount == 1)
        #expect(try await transcript.cancelWriteCount() == 1)
        #expect(await transcript.cleanupCount == 1)
    }

    @Test("cancel後のlate duplicate channelは先行ownerをcleanupしない")
    func lateDuplicateChannelAfterCancellationDoesNotDisturbOwner() async throws {
        let transcript = SyntheticInteractiveTranscript()
        let firstReadGate = SyntheticInteractiveGate()
        let channel = try SyntheticInteractiveChannel(
            transcript: transcript,
            readSteps: [
                .bytes(syntheticReadyFrame()),
                .bytes(syntheticStartedFrame()),
                .blocked(gate: firstReadGate, result: .endOfFile)
            ]
        )
        let firstFactory = SyntheticInteractiveFactory(
            transcript: transcript,
            result: .channel(channel)
        )
        let secondFactory = SyntheticInteractiveLateReturningFactory(
            transcript: transcript,
            channel: channel,
            delay: .milliseconds(80)
        )
        let firstTransport = CodexSyntheticInteractiveTransport(factory: firstFactory)
        let secondTransport = CodexSyntheticInteractiveTransport(factory: secondFactory)
        let firstTask = Task {
            try await firstTransport.run(syntheticInteractiveRequest())
        }
        await waitForSyntheticReads(3, transcript: transcript)
        let writesBeforeSecondOpen = await transcript.writes.count
        let readsBeforeSecondOpen = await transcript.readCount

        let secondError = await capturedSyntheticInteractiveError {
            _ = try await secondTransport.run(
                syntheticInteractiveRequest(attestationTimeout: .milliseconds(20))
            )
        }

        #expect(secondError == .attestationTimedOut)
        #expect(await transcript.factoryOpenCount == 2)
        #expect(await transcript.writes.count == writesBeforeSecondOpen)
        #expect(await transcript.readCount == readsBeforeSecondOpen)
        #expect(await transcript.cleanupCount == 0)

        await firstTransport.cancel()
        let firstError = await capturedSyntheticInteractiveError {
            _ = try await firstTask.value
        }
        #expect(firstError == .cancelled)
        #expect(await transcript.cancellationCount == 1)
        #expect(try await transcript.cancelWriteCount() == 1)
        #expect(await transcript.cleanupCount == 1)
    }

    @Test("cleanup済みchannelはtransport存続中もreuse registryから解放される")
    func cleanedChannelIsNotStronglyRetainedByRegistry() async throws {
        let transcript = SyntheticInteractiveTranscript()
        var channel: SyntheticInteractiveChannel? = try SyntheticInteractiveChannel(
            transcript: transcript,
            readSteps: [
                .bytes(syntheticReadyFrame()),
                .bytes(syntheticStartedFrame()),
                .bytes(syntheticFailedFrame()),
                .endOfFile
            ]
        )
        let weakProbe = try SyntheticInteractiveWeakChannelProbe(
            channel: #require(channel)
        )
        let factory = try SyntheticInteractiveSequenceFactory(
            transcript: transcript,
            results: [.channel(#require(channel))]
        )
        let transport = CodexSyntheticInteractiveTransport(factory: factory)

        _ = try await transport.run(syntheticInteractiveRequest())
        channel = nil
        for _ in 0 ..< 10 where weakProbe.channel != nil {
            await Task.yield()
        }

        #expect(weakProbe.channel == nil)
        withExtendedLifetime(transport) {}
    }

    @Test("terminal+EOF後cleanup中の明示cancelはresultを破棄しchannel I/Oを増やさない")
    func explicitCancellationDuringCleanupSuppressesTerminal() async throws {
        let cleanupGate = SyntheticInteractiveGate()
        let harness = try syntheticInteractiveHarness(
            readSteps: [
                .bytes(syntheticReadyFrame()),
                .bytes(syntheticStartedFrame()),
                .bytes(syntheticCompletedFrame()),
                .endOfFile
            ],
            cleanupGate: cleanupGate
        )
        let task = Task {
            try await harness.transport.run(syntheticInteractiveRequest())
        }
        await waitForSyntheticCleanups(1, transcript: harness.transcript)
        let writesBeforeCancel = await harness.transcript.writes.count
        let readsBeforeCancel = await harness.transcript.readCount

        await harness.transport.cancel()
        await cleanupGate.open()
        let error = await capturedSyntheticInteractiveError {
            _ = try await task.value
        }

        #expect(error == .cancelled)
        #expect(await harness.transcript.cancellationCount == 0)
        #expect(await harness.transcript.ioAfterCleanupCount == 0)
        #expect(await harness.transcript.writes.count == writesBeforeCancel)
        #expect(await harness.transcript.readCount == readsBeforeCancel)

        await harness.transport.cancel()
        #expect(await harness.transcript.cancellationCount == 0)
        #expect(await harness.transcript.ioAfterCleanupCount == 0)
    }

    @Test("terminal+EOF後cleanup中のTask.cancelはresultを破棄しchannel I/Oを増やさない")
    func taskCancellationDuringCleanupSuppressesTerminal() async throws {
        let cleanupGate = SyntheticInteractiveGate()
        let harness = try syntheticInteractiveHarness(
            readSteps: [
                .bytes(syntheticReadyFrame()),
                .bytes(syntheticStartedFrame()),
                .bytes(syntheticCompletedFrame()),
                .endOfFile
            ],
            cleanupGate: cleanupGate
        )
        let task = Task {
            try await harness.transport.run(syntheticInteractiveRequest())
        }
        await waitForSyntheticCleanups(1, transcript: harness.transcript)
        let writesBeforeCancel = await harness.transcript.writes.count
        let readsBeforeCancel = await harness.transcript.readCount

        task.cancel()
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        await cleanupGate.open()
        let error = await capturedSyntheticInteractiveError {
            _ = try await task.value
        }

        #expect(error == .cancelled)
        #expect(await harness.transcript.cancellationCount == 0)
        #expect(await harness.transcript.ioAfterCleanupCount == 0)
        #expect(await harness.transcript.writes.count == writesBeforeCancel)
        #expect(await harness.transcript.readCount == readsBeforeCancel)

        await harness.transport.cancel()
        #expect(await harness.transcript.cancellationCount == 0)
        #expect(await harness.transcript.ioAfterCleanupCount == 0)
    }

    @Test("protocol failure後cleanup中のlate cancelは既存failureを維持する")
    func lateCancellationDuringCleanupPreservesProtocolFailure() async {
        let cleanupGate = SyntheticInteractiveGate()
        let harness = syntheticInteractiveHarness(
            readSteps: [.endOfFile],
            cleanupGate: cleanupGate
        )
        let task = Task {
            try await harness.transport.run(syntheticInteractiveRequest())
        }
        await waitForSyntheticCleanups(1, transcript: harness.transcript)
        let writesBeforeCancel = await harness.transcript.writes.count
        let readsBeforeCancel = await harness.transcript.readCount

        await harness.transport.cancel()
        await cleanupGate.open()
        let error = await capturedSyntheticInteractiveError {
            _ = try await task.value
        }

        #expect(error == .protocolFailure(.unexpectedEOF))
        #expect(await harness.transcript.cancellationCount == 0)
        #expect(await harness.transcript.ioAfterCleanupCount == 0)
        #expect(await harness.transcript.writes.count == writesBeforeCancel)
        #expect(await harness.transcript.readCount == readsBeforeCancel)

        await harness.transport.cancel()
        #expect(await harness.transcript.cancellationCount == 0)
        #expect(await harness.transcript.ioAfterCleanupCount == 0)
    }
}
