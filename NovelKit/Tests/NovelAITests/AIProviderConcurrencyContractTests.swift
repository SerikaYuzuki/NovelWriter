import NovelAI
import Testing

private actor ConcurrentAIProvider: AIProvider {
    let descriptor: AIProviderDescriptor

    init(descriptor: AIProviderDescriptor) {
        self.descriptor = descriptor
    }

    func start(request _: AIConfirmedRequest, events: AIProviderEventContinuation) async {
        events.yieldStarted()
        events.complete(
            structuredOutput: #"{"replacement":"校正後","summary":"完了","warnings":[]}"#,
            usage: AIUsage(outputTokens: 2)
        )
    }
}

private let concurrencyProviderDescriptor = AIProviderDescriptor(
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

private let concurrencyBudget = AIRequestBudget(
    maximumInputCharacters: 1000,
    maximumInputUTF8Bytes: 4000,
    maximumOutputCharacters: 2000,
    maximumOutputUTF8Bytes: 8000,
    maximumOutputTokens: 1000,
    timeoutSeconds: 30
)

@Test("actor providerの不変stored descriptorはactor hopなしでprotocolへ準拠できる")
func actorProviderStoredDescriptorCanConform() async throws {
    let provider = ConcurrentAIProvider(descriptor: concurrencyProviderDescriptor)
    let request = try AIRequestDraft(selectedText: "校正対象", budget: concurrencyBudget)
        .preview(for: concurrencyProviderDescriptor)
        .confirmForSending()

    // `await`なしで読めることをcompile-timeで固定する。
    #expect(provider.descriptor == concurrencyProviderDescriptor)

    let events = await collectConcurrencyEvents(
        AIProviderExecutor.events(for: request, using: provider)
    )

    #expect(
        events == [
            .started,
            .completed(
                AIResult(
                    replacement: "校正後",
                    summary: "完了",
                    usage: AIUsage(outputTokens: 2)
                )
            )
        ]
    )
}

private func collectConcurrencyEvents(
    _ stream: AIProviderEventStream
) async -> [AIProviderEvent] {
    var events: [AIProviderEvent] = []
    for await event in stream {
        events.append(event)
    }
    return events
}
