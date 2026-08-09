/// Providerが生のSDK errorや未検証resultをstreamへ直接流さないためのdomain所有境界。
public struct AIProviderEventStream: AsyncSequence, Sendable {
    public typealias Element = AIProviderEvent
    public typealias AsyncIterator = AsyncStream<Element>.Iterator

    private let stream: AsyncStream<Element>

    /// requestとproviderの一致、output budget、terminal eventを共通実装で検証する。
    /// Provider adapterは`continuation`だけを使い、生のstream continuationへ触れない。
    init(
        request: AIConfirmedRequest,
        provider: AIProviderDescriptor,
        deadline: ContinuousClock.Instant,
        _ build: @escaping @Sendable (AIProviderEventContinuation) -> Void
    ) {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self)
        let providerContinuation = AIProviderEventContinuation(
            request: request,
            continuation: continuation,
            deadline: deadline
        )
        continuation.onTermination = { @Sendable termination in
            guard case .cancelled = termination else { return }
            providerContinuation.consumerCancelled()
        }
        self.stream = stream

        guard request.outbound.provider == provider else {
            providerContinuation.fail(.providerMismatch)
            return
        }
        providerContinuation.armTimeout()
        build(providerContinuation)
    }

    public func makeAsyncIterator() -> AsyncIterator {
        stream.makeAsyncIterator()
    }
}
