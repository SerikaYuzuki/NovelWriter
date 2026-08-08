import Foundation
@testable import NovelAI
import Testing

private actor RequestRecorder {
    private var request: AIConfirmedRequest?

    func record(_ request: AIConfirmedRequest) {
        self.request = request
    }

    func recordedRequest() -> AIConfirmedRequest? {
        request
    }
}

private actor CancellationProbe {
    private var cancellationCount = 0

    func markCancelled() {
        cancellationCount += 1
    }

    func recordedCancellationCount() -> Int {
        cancellationCount
    }
}

private final class DeadlineCancellationRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    private var externalEffectCount = 0

    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
    }

    func startExternalEffectIfAllowed() {
        lock.lock()
        if !isCancelled {
            externalEffectCount += 1
        }
        lock.unlock()
    }

    func state() -> (isCancelled: Bool, externalEffectCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (isCancelled, externalEffectCount)
    }
}

private struct FakeAIProvider: AIProvider {
    let descriptor: AIProviderDescriptor
    let recorder: RequestRecorder
    let structuredOutput: String
    let usage: AIUsage

    func start(request: AIConfirmedRequest, events: AIProviderEventContinuation) async {
        await recorder.record(request)
        events.yieldStarted()
        events.complete(structuredOutput: structuredOutput, usage: usage)
    }
}

private struct ScriptedAIProvider: AIProvider {
    let descriptor: AIProviderDescriptor
    let script: @Sendable (AIProviderEventContinuation) -> Void

    func start(request _: AIConfirmedRequest, events: AIProviderEventContinuation) async {
        script(events)
    }
}

private let providerDescriptor = AIProviderDescriptor(
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

private let providerBudget = AIRequestBudget(
    maximumInputCharacters: 1000,
    maximumInputUTF8Bytes: 4000,
    maximumOutputCharacters: 2000,
    maximumOutputUTF8Bytes: 8000,
    maximumOutputTokens: 1000,
    timeoutSeconds: 30
)

@Test("providerはconfirmed requestだけを受け取りresultをstreamする")
func fakeProviderReceivesConfirmedRequest() async throws {
    let recorder = RequestRecorder()
    let result = AIResult(
        replacement: "校正後",
        summary: "表記を整えました",
        warnings: ["意味の最終確認が必要です"],
        usage: AIUsage(inputTokens: 12, outputTokens: 8)
    )
    let provider = try FakeAIProvider(
        descriptor: providerDescriptor,
        recorder: recorder,
        structuredOutput: structuredOutput(for: result),
        usage: result.usage
    )
    let request = try confirmedRequest()

    let events = await collect(AIProviderExecutor.events(for: request, using: provider))

    #expect(events == [.started, .completed(result)])
    #expect(await recorder.recordedRequest()?.outbound == request.outbound)
}

@Test("provider descriptor不一致はbuildを実行せずtyped terminalでfail closedする")
func providerMismatchFailsClosed() async throws {
    let otherDescriptor = AIProviderDescriptor(
        id: .openRouter,
        displayName: "OpenRouter",
        destination: "OpenRouter",
        modelID: "example/model",
        modelDisplayName: "Example Model",
        sessionStorage: .providerReportedNotUsed,
        trainingUse: .notVerified,
        authentication: .apiKey,
        capabilities: [.streaming, .cancellation, .usageReporting]
    )
    let recorder = RequestRecorder()
    let provider = FakeAIProvider(
        descriptor: otherDescriptor,
        recorder: recorder,
        structuredOutput: #"{"replacement":"","summary":"","warnings":[]}"#,
        usage: AIUsage(outputTokens: 0)
    )

    let events = try await collect(
        AIProviderExecutor.events(for: confirmedRequest(), using: provider)
    )

    #expect(events == [.failed(.providerMismatch)])
    #expect(await recorder.recordedRequest() == nil)
}

@Test("domain continuationはraw structured output超過をtyped terminalへ変換する")
func fakeProviderRejectsOversizedStructuredOutput() async throws {
    let oversized = AIResult(
        replacement: String(repeating: "あ", count: providerBudget.maximumOutputCharacters + 1),
        summary: "",
        usage: AIUsage(outputTokens: 1)
    )
    let rawOutput = try structuredOutput(for: oversized)
    let provider = FakeAIProvider(
        descriptor: providerDescriptor,
        recorder: RequestRecorder(),
        structuredOutput: rawOutput,
        usage: oversized.usage
    )

    let events = try await collect(
        AIProviderExecutor.events(for: confirmedRequest(), using: provider)
    )

    #expect(
        events == [
            .started,
            .failed(
                .outputCharacterLimitExceeded(
                    limit: providerBudget.maximumOutputCharacters,
                    actual: rawOutput.count
                )
            )
        ]
    )
}

@Test("delta累計が上限を超える前にtyped terminalで停止する")
func deltaLimitFailsClosed() async throws {
    let probe = CancellationProbe()
    let request = try AIRequestDraft(
        selectedText: "校正対象",
        budget: AIRequestBudget(
            maximumInputCharacters: 1000,
            maximumInputUTF8Bytes: 4000,
            maximumOutputCharacters: 3,
            maximumOutputUTF8Bytes: 100,
            maximumOutputTokens: 100,
            timeoutSeconds: 30
        )
    )
    .preview(for: providerDescriptor)
    .confirmForSending()
    let provider = ScriptedAIProvider(descriptor: providerDescriptor) { events in
        events.yieldStarted()
        events.yieldReplacementDelta("修正")
        events.yieldReplacementDelta("案追")
        events.onUpstreamCancellation {
            Task { await probe.markCancelled() }
        }
        events.complete(
            structuredOutput: #"{"replacement":"到達しない","summary":"","warnings":[]}"#,
            usage: AIUsage(outputTokens: 1)
        )
    }

    let events = await collect(AIProviderExecutor.events(for: request, using: provider))

    #expect(
        events == [
            .started,
            .replacementDelta("修正"),
            .failed(.outputCharacterLimitExceeded(limit: 3, actual: 4))
        ]
    )
    #expect(await waitForCancellationCount(probe) == 1)
}

@Test("deltaのUTF-8 byte累計も文字数と独立して制限する")
func deltaByteLimitFailsClosed() async throws {
    let request = try AIRequestDraft(
        selectedText: "校正対象",
        budget: AIRequestBudget(
            maximumInputCharacters: 1000,
            maximumInputUTF8Bytes: 4000,
            maximumOutputCharacters: 10,
            maximumOutputUTF8Bytes: 3,
            maximumOutputTokens: 100,
            timeoutSeconds: 30
        )
    )
    .preview(for: providerDescriptor)
    .confirmForSending()
    let provider = ScriptedAIProvider(descriptor: providerDescriptor) { events in
        events.yieldStarted()
        events.yieldReplacementDelta("😀")
    }

    let events = await collect(AIProviderExecutor.events(for: request, using: provider))

    #expect(
        events == [
            .started,
            .failed(.outputUTF8ByteLimitExceeded(limit: 3, actual: 4))
        ]
    )
}

@Test("wall-clock timeoutはtyped terminalとupstream cancellationを1回発生させる")
func timeoutFailsClosedAndStopsUpstream() async throws {
    let probe = CancellationProbe()
    let request = try AIRequestDraft(
        selectedText: "校正対象",
        budget: AIRequestBudget(
            maximumInputCharacters: 1000,
            maximumInputUTF8Bytes: 4000,
            maximumOutputCharacters: 100,
            maximumOutputUTF8Bytes: 400,
            maximumOutputTokens: 100,
            timeoutSeconds: 1
        )
    )
    .preview(for: providerDescriptor)
    .confirmForSending()
    let provider = ScriptedAIProvider(descriptor: providerDescriptor) { events in
        events.onUpstreamCancellation {
            Task { await probe.markCancelled() }
        }
        events.yieldStarted()
    }

    let events = await collect(AIProviderExecutor.events(for: request, using: provider))

    #expect(events == [.started, .failed(.timedOut)])
    #expect(await waitForCancellationCount(probe) == 1)
}

@Test("eventはtimeout taskと独立してabsolute deadline後の成功を拒否する")
func eventAfterAbsoluteDeadlineFailsClosed() async throws {
    let request = try confirmedRequest()
    let (rawStream, rawContinuation) = AsyncStream.makeStream(of: AIProviderEvent.self)
    let providerContinuation = AIProviderEventContinuation(
        request: request,
        continuation: rawContinuation,
        deadline: ContinuousClock().now.advanced(by: .milliseconds(-1))
    )

    providerContinuation.yieldStarted()
    providerContinuation.complete(
        structuredOutput: #"{"replacement":"期限後","summary":"完了","warnings":[]}"#,
        usage: AIUsage(outputTokens: 2)
    )

    var events: [AIProviderEvent] = []
    for await event in rawStream {
        events.append(event)
    }
    #expect(events == [.failed(.timedOut)])
}

@Test("deadline後のcancellation handler登録は外部副作用より先に同期停止する")
func cancellationRegistrationAfterDeadlinePreventsExternalEffect() async throws {
    let request = try confirmedRequest()
    let relay = DeadlineCancellationRelay()
    let (rawStream, rawContinuation) = AsyncStream.makeStream(of: AIProviderEvent.self)
    let providerContinuation = AIProviderEventContinuation(
        request: request,
        continuation: rawContinuation,
        deadline: ContinuousClock().now.advanced(by: .milliseconds(10))
    )

    #expect(providerContinuation.claimProviderStartIfActive())
    try await Task.sleep(for: .milliseconds(20))
    providerContinuation.onUpstreamCancellation {
        relay.cancel()
    }
    relay.startExternalEffectIfAllowed()

    var events: [AIProviderEvent] = []
    for await event in rawStream {
        events.append(event)
    }
    let state = relay.state()
    #expect(events == [.failed(.timedOut)])
    #expect(state.isCancelled)
    #expect(state.externalEffectCount == 0)
}

@Test("terminal eventは最初の1回だけを通す")
func terminalEventIsExactlyOnce() async throws {
    let probe = CancellationProbe()
    let request = try confirmedRequest()
    let result = AIResult(
        replacement: "校正後",
        summary: "完了",
        usage: AIUsage(outputTokens: 2)
    )
    let provider = ScriptedAIProvider(descriptor: providerDescriptor) { events in
        events.onUpstreamCancellation {
            Task { await probe.markCancelled() }
        }
        events.yieldStarted()
        events.complete(
            structuredOutput: #"{"replacement":"校正後","summary":"完了","warnings":[]}"#,
            usage: result.usage
        )
        events.fail(.providerUnavailable)
        events.complete(
            structuredOutput: #"{"replacement":"校正後","summary":"完了","warnings":[]}"#,
            usage: result.usage
        )
    }

    let events = await collect(AIProviderExecutor.events(for: request, using: provider))

    #expect(events == [.started, .completed(result)])
    #expect(await probe.recordedCancellationCount() == 0)
}

private func confirmedRequest() throws -> AIConfirmedRequest {
    try AIRequestDraft(selectedText: "校正対象", budget: providerBudget)
        .preview(for: providerDescriptor)
        .confirmForSending()
}

private func collect(_ stream: AIProviderEventStream) async -> [AIProviderEvent] {
    var events: [AIProviderEvent] = []
    for await event in stream {
        events.append(event)
    }
    return events
}

private func waitForCancellationCount(_ probe: CancellationProbe) async -> Int {
    for _ in 0 ..< 100 {
        let count = await probe.recordedCancellationCount()
        if count > 0 {
            return count
        }
        await Task.yield()
    }
    return await probe.recordedCancellationCount()
}

private func structuredOutput(for result: AIResult) throws -> String {
    let object: [String: Any] = [
        "replacement": result.replacement,
        "summary": result.summary,
        "warnings": result.warnings
    ]
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return try #require(String(data: data, encoding: .utf8))
}
