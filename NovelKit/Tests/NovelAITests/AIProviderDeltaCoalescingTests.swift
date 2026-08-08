import NovelAI
import Testing

private struct FineGrainedDeltaProvider: AIProvider {
    let descriptor: AIProviderDescriptor
    let deltaCount: Int

    func start(request _: AIConfirmedRequest, events: AIProviderEventContinuation) async {
        events.yieldStarted()
        for _ in 0 ..< deltaCount {
            events.yieldReplacementDelta("a")
        }
        events.complete(
            structuredOutput: #"{"replacement":"校正後","summary":"完了","warnings":[]}"#,
            usage: AIUsage(outputTokens: 10)
        )
    }
}

private let deltaCoalescingDescriptor = AIProviderDescriptor(
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

@Test("細切れdeltaをboundedなevent数へまとめて本文を欠落させない")
func fineGrainedDeltasAreCoalesced() async throws {
    let deltaCount = 600
    let budget = AIRequestBudget(
        maximumInputCharacters: 2000,
        maximumInputUTF8Bytes: 8000,
        maximumOutputCharacters: 2000,
        maximumOutputUTF8Bytes: 8000,
        maximumOutputTokens: 1000,
        timeoutSeconds: 30
    )
    let request = try AIRequestDraft(selectedText: "校正する本文", budget: budget)
        .preview(for: deltaCoalescingDescriptor)
        .confirmForSending()
    let provider = FineGrainedDeltaProvider(
        descriptor: deltaCoalescingDescriptor,
        deltaCount: deltaCount
    )

    var collected: [AIProviderEvent] = []
    for await event in AIProviderExecutor.events(for: request, using: provider) {
        collected.append(event)
    }
    let deltas = collected.compactMap { event -> String? in
        guard case let .replacementDelta(delta) = event else { return nil }
        return delta
    }

    #expect(collected.first == .started)
    #expect(deltas.joined() == String(repeating: "a", count: deltaCount))
    #expect(deltas.count == 3)
    #expect(
        collected.last == .completed(
            AIResult(
                replacement: "校正後",
                summary: "完了",
                usage: AIUsage(outputTokens: 10)
            )
        )
    )
}
