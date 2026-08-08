import Foundation
import NovelAI
import Testing

private actor ConsumerCancellationProbe {
    private var started = false
    private var cancelled = false

    func markStarted() {
        started = true
    }

    func markCancelled() {
        cancelled = true
    }

    func state() -> (started: Bool, cancelled: Bool) {
        (started, cancelled)
    }
}

private final class ConsumerProducerRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var isCancellationRequested = false

    func install(_ task: Task<Void, Never>) {
        lock.lock()
        if isCancellationRequested {
            lock.unlock()
            task.cancel()
            return
        }
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        isCancellationRequested = true
        let task = task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }
}

private struct ConsumerSuspendingProvider: AIProvider {
    let descriptor: AIProviderDescriptor
    let probe: ConsumerCancellationProbe

    func start(request _: AIConfirmedRequest, events: AIProviderEventContinuation) async {
        let relay = ConsumerProducerRelay()
        events.onUpstreamCancellation {
            relay.cancel()
        }
        let producer = Task {
            do {
                await probe.markStarted()
                events.yieldStarted()
                try await Task.sleep(for: .seconds(60))
                events.fail(.timedOut)
            } catch is CancellationError {
                await probe.markCancelled()
            } catch {
                events.fail(.invalidResponse)
            }
        }
        relay.install(producer)
    }
}

private let consumerProviderDescriptor = AIProviderDescriptor(
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

@Test("consumer taskのcancelはfake providerの外部処理へ伝播する")
func cancellationStopsProviderWork() async throws {
    let probe = ConsumerCancellationProbe()
    let provider = ConsumerSuspendingProvider(
        descriptor: consumerProviderDescriptor,
        probe: probe
    )
    let budget = AIRequestBudget(
        maximumInputCharacters: 1000,
        maximumInputUTF8Bytes: 4000,
        maximumOutputCharacters: 2000,
        maximumOutputUTF8Bytes: 8000,
        maximumOutputTokens: 1000,
        timeoutSeconds: 30
    )
    let request = try AIRequestDraft(selectedText: "校正対象", budget: budget)
        .preview(for: consumerProviderDescriptor)
        .confirmForSending()
    let consumer = Task {
        for await _ in AIProviderExecutor.events(for: request, using: provider) {}
    }

    #expect(await waitForConsumerState(probe, expected: (true, false)))
    consumer.cancel()
    await consumer.value
    #expect(await waitForConsumerState(probe, expected: (true, true)))
}

private func waitForConsumerState(
    _ probe: ConsumerCancellationProbe,
    expected: (started: Bool, cancelled: Bool)
) async -> Bool {
    for _ in 0 ..< 100 {
        let state = await probe.state()
        if state == expected {
            return true
        }
        await Task.yield()
    }
    return false
}
