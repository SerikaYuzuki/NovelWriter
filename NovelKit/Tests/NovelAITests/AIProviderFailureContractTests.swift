import Foundation
import NovelAI
import Testing

private actor FailureCancellationProbe {
    private var count = 0

    func record() {
        count += 1
    }

    func recordedCount() -> Int {
        count
    }
}

private actor ProviderStartProbe {
    private var count = 0

    func record() {
        count += 1
    }

    func recordedCount() -> Int {
        count
    }
}

private final class DescriptorGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)

    func blockGetter() {
        entered.signal()
        resume.wait()
    }

    func waitUntilEntered() -> Bool {
        entered.wait(timeout: .now() + 2) == .success
    }

    func release() {
        resume.signal()
    }
}

private struct FailureScriptProvider: AIProvider {
    let descriptor: AIProviderDescriptor
    let script: @Sendable (AIProviderEventContinuation) -> Void

    func start(request _: AIConfirmedRequest, events: AIProviderEventContinuation) async {
        script(events)
    }
}

private struct StartRecordingProvider: AIProvider {
    let descriptor: AIProviderDescriptor
    let probe: ProviderStartProbe

    func start(request _: AIConfirmedRequest, events: AIProviderEventContinuation) async {
        await probe.record()
        events.yieldStarted()
        events.fail(.providerUnavailable)
    }
}

private struct BlockingDescriptorProvider: AIProvider {
    let advertisedDescriptor: AIProviderDescriptor
    let gate: DescriptorGate
    let probe: ProviderStartProbe

    var descriptor: AIProviderDescriptor {
        gate.blockGetter()
        return advertisedDescriptor
    }

    func start(request _: AIConfirmedRequest, events: AIProviderEventContinuation) async {
        await probe.record()
        events.yieldStarted()
        events.fail(.providerUnavailable)
    }
}

private let failureProviderDescriptor = AIProviderDescriptor(
    id: .codex,
    displayName: "Codex",
    destination: "OpenAI",
    modelID: "codex-model",
    modelDisplayName: "Codex Model",
    sessionStorage: .notVerified,
    trainingUse: .notVerified,
    authentication: .apiKey,
    capabilities: [.streaming, .cancellation, .usageReporting]
)

@Test("executor呼出前にcancel済みでもconfirmationを消費しproviderを開始しない")
func preCancelledExecutionNeverStartsProvider() async throws {
    let probe = ProviderStartProbe()
    let provider = StartRecordingProvider(
        descriptor: failureProviderDescriptor,
        probe: probe
    )
    let request = try failureRequest()
    let streamTask = Task {
        withUnsafeCurrentTask { task in
            task?.cancel()
        }
        return AIProviderExecutor.events(for: request, using: provider)
    }

    let events = await collectFailureEvents(streamTask.value)
    let reuseEvents = await collectFailureEvents(
        AIProviderExecutor.events(for: request, using: provider)
    )

    #expect(events == [.failed(.cancelled)])
    #expect(reuseEvents == [.failed(.confirmationAlreadyUsed)])
    #expect(await probe.recordedCount() == 0)
}

@Test("descriptor取得中のcancelはconfirmationを消費しprovider開始と再利用を拒否する")
func cancellationDuringDescriptorReadNeverStartsProvider() async throws {
    let probe = ProviderStartProbe()
    let gate = DescriptorGate()
    let provider = BlockingDescriptorProvider(
        advertisedDescriptor: failureProviderDescriptor,
        gate: gate,
        probe: probe
    )
    let request = try failureRequest()
    let streamTask = Task {
        AIProviderExecutor.events(for: request, using: provider)
    }

    #expect(gate.waitUntilEntered())
    streamTask.cancel()
    gate.release()
    let events = await collectFailureEvents(streamTask.value)
    let retryProvider = StartRecordingProvider(
        descriptor: failureProviderDescriptor,
        probe: probe
    )
    let reuseEvents = await collectFailureEvents(
        AIProviderExecutor.events(for: request, using: retryProvider)
    )

    #expect(events == [.failed(.cancelled)])
    #expect(reuseEvents == [.failed(.confirmationAlreadyUsed)])
    #expect(await probe.recordedCount() == 0)
}

@Test("descriptor timeoutはconfirmationを消費しprovider開始と再利用を拒否する")
func descriptorReadIsIncludedInWallClockTimeout() async throws {
    let probe = ProviderStartProbe()
    let gate = DescriptorGate()
    let provider = BlockingDescriptorProvider(
        advertisedDescriptor: failureProviderDescriptor,
        gate: gate,
        probe: probe
    )
    let request = try failureRequest(timeoutSeconds: 1)
    let streamTask = Task {
        AIProviderExecutor.events(for: request, using: provider)
    }

    #expect(gate.waitUntilEntered())
    try await Task.sleep(for: .milliseconds(1100))
    gate.release()
    let events = await collectFailureEvents(streamTask.value)
    let retryProvider = StartRecordingProvider(
        descriptor: failureProviderDescriptor,
        probe: probe
    )
    let reuseEvents = await collectFailureEvents(
        AIProviderExecutor.events(for: request, using: retryProvider)
    )

    #expect(events == [.failed(.timedOut)])
    #expect(reuseEvents == [.failed(.confirmationAlreadyUsed)])
    #expect(await probe.recordedCount() == 0)
}

@Test("同じpreviewの重複confirmationは最初の1件だけproviderを開始する")
func confirmationIsOneShotAcrossRepeatedConfirmation() async throws {
    let probe = ProviderStartProbe()
    let provider = StartRecordingProvider(
        descriptor: failureProviderDescriptor,
        probe: probe
    )
    let preview = try failurePreview()
    let firstRequest = preview.confirmForSending()
    let secondRequest = preview.confirmForSending()

    async let first = collectFailureEvents(
        AIProviderExecutor.events(for: firstRequest, using: provider)
    )
    async let second = collectFailureEvents(
        AIProviderExecutor.events(for: secondRequest, using: provider)
    )
    let outcomes = await [first, second]

    #expect(outcomes.contains([.started, .failed(.providerUnavailable)]))
    #expect(outcomes.contains([.failed(.confirmationAlreadyUsed)]))
    #expect(await probe.recordedCount() == 1)
}

@Test("adapterのtyped failureはupstream cancellationをexactly onceで実行する")
func adapterFailureStopsUpstreamExactlyOnce() async throws {
    let probe = FailureCancellationProbe()
    let provider = FailureScriptProvider(descriptor: failureProviderDescriptor) { events in
        events.onUpstreamCancellation {
            Task { await probe.record() }
        }
        events.yieldStarted()
        events.fail(.providerUnavailable)
        events.fail(.timedOut)
    }

    let events = try await collectFailureEvents(
        AIProviderExecutor.events(for: failureRequest(), using: provider)
    )

    #expect(events == [.started, .failed(.providerUnavailable)])
    #expect(await waitForFailureCancellation(probe) == 1)
}

@Test("providerはraw structured outputのstrict schema検証を迂回できない")
func invalidStructuredOutputFailsClosed() async throws {
    let probe = FailureCancellationProbe()
    let provider = FailureScriptProvider(descriptor: failureProviderDescriptor) { events in
        events.onUpstreamCancellation {
            Task { await probe.record() }
        }
        events.yieldStarted()
        events.complete(
            structuredOutput: #"{"replacement":"修正","summary":"要約","warnings":[],"extra":true}"#,
            usage: AIUsage(outputTokens: 4)
        )
    }

    let events = try await collectFailureEvents(
        AIProviderExecutor.events(for: failureRequest(), using: provider)
    )

    #expect(events == [.started, .failed(.invalidResponse)])
    #expect(await waitForFailureCancellation(probe) == 1)
}

@Test("domain failure後のlate cancellation handlerは最初の1件だけを実行する")
func lateCancellationHandlerRunsOnlyOnce() async throws {
    let probe = FailureCancellationProbe()
    let request = try failureRequest(maximumOutputCharacters: 1)
    let provider = FailureScriptProvider(descriptor: failureProviderDescriptor) { events in
        events.yieldStarted()
        events.yieldReplacementDelta("超過")
        events.onUpstreamCancellation {
            Task { await probe.record() }
        }
        events.onUpstreamCancellation {
            Task { await probe.record() }
        }
    }

    let events = await collectFailureEvents(
        AIProviderExecutor.events(for: request, using: provider)
    )

    #expect(events == [.started, .failed(.outputCharacterLimitExceeded(limit: 1, actual: 2))])
    #expect(await waitForFailureCancellation(probe) == 1)
}

private func failureRequest(
    maximumOutputCharacters: Int = 100,
    timeoutSeconds: Int = 10
) throws -> AIConfirmedRequest {
    try failurePreview(
        maximumOutputCharacters: maximumOutputCharacters,
        timeoutSeconds: timeoutSeconds
    ).confirmForSending()
}

private func failurePreview(
    maximumOutputCharacters: Int = 100,
    timeoutSeconds: Int = 10
) throws -> AIOutboundPreview {
    let budget = AIRequestBudget(
        maximumInputCharacters: 1000,
        maximumInputUTF8Bytes: 4000,
        maximumOutputCharacters: maximumOutputCharacters,
        maximumOutputUTF8Bytes: 400,
        maximumOutputTokens: 100,
        timeoutSeconds: timeoutSeconds
    )
    return try AIRequestDraft(selectedText: "校正対象", budget: budget)
        .preview(for: failureProviderDescriptor)
}

private func collectFailureEvents(
    _ stream: AIProviderEventStream
) async -> [AIProviderEvent] {
    var events: [AIProviderEvent] = []
    for await event in stream {
        events.append(event)
    }
    return events
}

private func waitForFailureCancellation(_ probe: FailureCancellationProbe) async -> Int {
    for _ in 0 ..< 100 {
        let count = await probe.recordedCount()
        if count > 0 {
            return count
        }
        await Task.yield()
    }
    return await probe.recordedCount()
}
