import Foundation

/// Providerから逐次届くevent。完了結果にも原稿mutation APIは含まれない。
public enum AIProviderEvent: Sendable, Equatable {
    case started
    case replacementDelta(String)
    case completed(AIResult)
    case failed(AIError)
}

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

/// request/provider照合とstream生成をadapterの外側で所有する実行境界。
///
/// Adapterは比較に使うdescriptorを選べず、不一致の場合は`start`自体を呼ばない。
/// 最初の呼出しがconfirmationを消費し、その後のcancel／timeout／照合失敗でも再利用しない。
public enum AIProviderExecutor {
    public static func events(
        for request: AIConfirmedRequest,
        using provider: some AIProvider
    ) -> AIProviderEventStream {
        guard request.claimExecution() else {
            return terminalStream(for: request, error: .confirmationAlreadyUsed)
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(
            by: .seconds(request.outbound.budget.timeoutSeconds)
        )
        guard !Task.isCancelled else {
            return terminalStream(for: request, error: .cancelled)
        }
        let descriptor = provider.descriptor
        guard !Task.isCancelled else {
            return terminalStream(for: request, error: .cancelled)
        }
        let remaining = clock.now.duration(to: deadline)
        guard remaining > .zero else {
            return terminalStream(for: request, error: .timedOut)
        }
        return AIProviderEventStream(
            request: request,
            provider: descriptor,
            deadline: deadline
        ) { continuation in
            guard !Task.isCancelled else {
                continuation.fail(.cancelled)
                return
            }
            Task {
                guard continuation.claimProviderStartIfActive() else { return }
                await provider.start(request: request, events: continuation)
            }
        }
    }

    private static func terminalStream(
        for request: AIConfirmedRequest,
        error: AIError
    ) -> AIProviderEventStream {
        let deadline = ContinuousClock().now.advanced(
            by: .seconds(request.outbound.budget.timeoutSeconds)
        )
        return AIProviderEventStream(
            request: request,
            provider: request.outbound.provider,
            deadline: deadline
        ) { continuation in
            continuation.fail(error)
        }
    }
}

/// `AIProviderEventStream`へeventを送る唯一の公開経路。
///
/// started → zero or more deltas → completed/failedを強制し、terminalは最初の1回だけ通す。
/// consumer cancelまたはdomain側のfail-closed時は登録済みhandlerを1回だけ呼ぶ。
public final class AIProviderEventContinuation: @unchecked Sendable {
    private enum State {
        case awaitingStart
        case streaming
        case finished
        case consumerCancelled
    }

    private let request: AIConfirmedRequest
    private let continuation: AsyncStream<AIProviderEvent>.Continuation
    private let deadline: ContinuousClock.Instant
    private let lock = NSLock()
    private var state = State.awaitingStart
    private var deltaCharacterCount = 0
    private var deltaUTF8ByteCount = 0
    private var upstreamCancellationHandler: (@Sendable () -> Void)?
    private var hasRegisteredUpstreamCancellationHandler = false
    private var upstreamCancellationRequested = false
    private var hasClaimedProviderStart = false
    private var timeoutTask: Task<Void, Never>?

    init(
        request: AIConfirmedRequest,
        continuation: AsyncStream<AIProviderEvent>.Continuation,
        deadline: ContinuousClock.Instant
    ) {
        self.request = request
        self.continuation = continuation
        self.deadline = deadline
    }

    public func yieldStarted() {
        lock.lock()
        guard state == .awaitingStart else {
            lock.unlock()
            failFromDomain(.invalidResponse)
            return
        }
        let deadlineResult = finishIfDeadlineExceededLocked()
        guard !deadlineResult.exceeded else {
            lock.unlock()
            deadlineResult.cancellationHandler?()
            return
        }
        state = .streaming
        continuation.yield(.started)
        lock.unlock()
    }

    public func yieldReplacementDelta(_ delta: String) {
        lock.lock()
        guard state == .streaming else {
            lock.unlock()
            failFromDomain(.invalidResponse)
            return
        }
        let deadlineResult = finishIfDeadlineExceededLocked()
        guard !deadlineResult.exceeded else {
            lock.unlock()
            deadlineResult.cancellationHandler?()
            return
        }
        guard !delta.isEmpty else {
            lock.unlock()
            failFromDomain(.invalidResponse)
            return
        }

        let addition = deltaCharacterCount.addingReportingOverflow(delta.count)
        let actual = addition.overflow ? Int.max : addition.partialValue
        let exceedsCharacterLimit = addition.overflow ||
            actual > request.outbound.budget.maximumOutputCharacters
        guard !exceedsCharacterLimit else {
            let cancellationHandler = finishLocked(
                with: .failed(
                    .outputCharacterLimitExceeded(
                        limit: request.outbound.budget.maximumOutputCharacters,
                        actual: actual
                    )
                ),
                cancelUpstream: true
            )
            lock.unlock()
            cancellationHandler?()
            return
        }

        let byteAddition = deltaUTF8ByteCount.addingReportingOverflow(delta.utf8.count)
        let actualBytes = byteAddition.overflow ? Int.max : byteAddition.partialValue
        let exceedsByteLimit = byteAddition.overflow ||
            actualBytes > request.outbound.budget.maximumOutputUTF8Bytes
        guard !exceedsByteLimit else {
            let cancellationHandler = finishLocked(
                with: .failed(
                    .outputUTF8ByteLimitExceeded(
                        limit: request.outbound.budget.maximumOutputUTF8Bytes,
                        actual: actualBytes
                    )
                ),
                cancelUpstream: true
            )
            lock.unlock()
            cancellationHandler?()
            return
        }

        deltaCharacterCount = actual
        deltaUTF8ByteCount = actualBytes
        continuation.yield(.replacementDelta(delta))
        lock.unlock()
    }

    /// Providerのraw structured outputをdomainのbyte上限・exact schema・usage budgetで検証して完了する。
    /// AdapterはSDKがdecodeした任意の値から`AIResult`を直接構築して、この境界を迂回できない。
    public func complete(structuredOutput: String, usage: AIUsage) {
        lock.lock()
        guard state == .streaming else {
            lock.unlock()
            failFromDomain(.invalidResponse)
            return
        }
        var deadlineResult = finishIfDeadlineExceededLocked()
        guard !deadlineResult.exceeded else {
            lock.unlock()
            deadlineResult.cancellationHandler?()
            return
        }
        let cancellationHandler: (@Sendable () -> Void)?
        do {
            let validatedResult = try request.decodeResult(
                from: structuredOutput,
                usage: usage
            )
            deadlineResult = finishIfDeadlineExceededLocked()
            if deadlineResult.exceeded {
                cancellationHandler = deadlineResult.cancellationHandler
            } else {
                cancellationHandler = finishLocked(
                    with: .completed(validatedResult),
                    cancelUpstream: false
                )
            }
        } catch let error as AIError {
            deadlineResult = finishIfDeadlineExceededLocked()
            if deadlineResult.exceeded {
                cancellationHandler = deadlineResult.cancellationHandler
            } else {
                cancellationHandler = finishLocked(with: .failed(error), cancelUpstream: true)
            }
        } catch {
            deadlineResult = finishIfDeadlineExceededLocked()
            if deadlineResult.exceeded {
                cancellationHandler = deadlineResult.cancellationHandler
            } else {
                cancellationHandler = finishLocked(
                    with: .failed(.invalidResponse),
                    cancelUpstream: true
                )
            }
        }
        lock.unlock()
        cancellationHandler?()
    }

    public func fail(_ error: AIError) {
        lock.lock()
        guard state != .finished, state != .consumerCancelled else {
            lock.unlock()
            return
        }
        let deadlineResult = finishIfDeadlineExceededLocked()
        guard !deadlineResult.exceeded else {
            lock.unlock()
            deadlineResult.cancellationHandler?()
            return
        }
        let cancellationHandler = finishLocked(with: .failed(error), cancelUpstream: true)
        lock.unlock()
        cancellationHandler?()
    }

    /// consumer cancelまたはdomain側のfail-closed時に止める外部処理を登録する。
    public func onUpstreamCancellation(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        guard !hasRegisteredUpstreamCancellationHandler else {
            lock.unlock()
            return
        }
        hasRegisteredUpstreamCancellationHandler = true
        let deadlineResult = finishIfDeadlineExceededLocked()
        if deadlineResult.exceeded {
            upstreamCancellationRequested = false
            lock.unlock()
            handler()
            return
        }
        if state == .consumerCancelled || upstreamCancellationRequested {
            upstreamCancellationRequested = false
            lock.unlock()
            handler()
            return
        }
        guard state != .finished else {
            lock.unlock()
            return
        }
        upstreamCancellationHandler = handler
        lock.unlock()
    }

    fileprivate func consumerCancelled() {
        lock.lock()
        guard state != .finished, state != .consumerCancelled else {
            lock.unlock()
            return
        }
        state = .consumerCancelled
        timeoutTask?.cancel()
        timeoutTask = nil
        let handler = upstreamCancellationHandler
        upstreamCancellationHandler = nil
        upstreamCancellationRequested = handler == nil
        lock.unlock()
        handler?()
    }

    /// stream drop/cancelが先行した場合にadapterの開始自体を止めるexecutor専用lease。
    func claimProviderStartIfActive() -> Bool {
        lock.lock()
        let canClaim = !hasClaimedProviderStart &&
            state != .finished &&
            state != .consumerCancelled
        guard canClaim else {
            lock.unlock()
            return false
        }
        let deadlineResult = finishIfDeadlineExceededLocked()
        guard !deadlineResult.exceeded else {
            lock.unlock()
            deadlineResult.cancellationHandler?()
            return false
        }
        hasClaimedProviderStart = true
        lock.unlock()
        return true
    }

    fileprivate func armTimeout() {
        let remaining = ContinuousClock().now.duration(to: deadline)
        guard remaining > .zero else {
            failFromDomain(.timedOut)
            return
        }
        let task = Task { [weak self] in
            do {
                try await Task.sleep(for: remaining)
                self?.failFromDomain(.timedOut)
            } catch {
                // terminal eventまたはconsumer cancelで停止した。
            }
        }

        lock.lock()
        guard state != .finished, state != .consumerCancelled else {
            lock.unlock()
            task.cancel()
            return
        }
        timeoutTask = task
        lock.unlock()
    }

    private func failFromDomain(_ error: AIError) {
        lock.lock()
        guard state != .finished, state != .consumerCancelled else {
            lock.unlock()
            return
        }
        let deadlineResult = finishIfDeadlineExceededLocked()
        let cancellationHandler: (@Sendable () -> Void)? = if deadlineResult.exceeded {
            deadlineResult.cancellationHandler
        } else {
            finishLocked(with: .failed(error), cancelUpstream: true)
        }
        lock.unlock()
        cancellationHandler?()
    }

    private func finishIfDeadlineExceededLocked() -> (
        exceeded: Bool,
        cancellationHandler: (@Sendable () -> Void)?
    ) {
        guard state != .finished, state != .consumerCancelled else {
            return (false, nil)
        }
        guard ContinuousClock().now >= deadline else {
            return (false, nil)
        }
        return (
            true,
            finishLocked(with: .failed(.timedOut), cancelUpstream: true)
        )
    }

    private func finishLocked(
        with event: AIProviderEvent,
        cancelUpstream: Bool
    ) -> (@Sendable () -> Void)? {
        state = .finished
        timeoutTask?.cancel()
        timeoutTask = nil
        let handler = cancelUpstream ? upstreamCancellationHandler : nil
        upstreamCancellationRequested = cancelUpstream && handler == nil
        upstreamCancellationHandler = nil
        continuation.yield(event)
        continuation.finish()
        return handler
    }
}

/// Provider-neutralな実行境界。
///
/// - `start(request:events:)`は明示確認済みrequestだけを受け取る。
/// - 呼び出し側は`AIProviderExecutor`を使い、adapterからstreamを直接生成しない。
/// - Executor/streamがdescriptor一致、raw response文字／byte上限、exact response schema、
///   output budget、typed terminalを検証する。
/// - Adapterは`request.outbound.applicationPrompt`を文字列/byte変換以外で再構築・追記せず、
///   previewにない文脈・metadata・instructionをproviderへ追加しない。
/// - consumer cancel、timeout、budget超過時は`onUpstreamCancellation`から外部処理を止め、
///   孤児通信を残さない。
/// - Adapterの最初の外部副作用より前にcancellation handlerを登録する。handler登録前に
///   subprocessやnetwork送信を開始しない。
/// - SDK固有error、生stderr、pathをstreamへ出さず、必ず`AIError`へ正規化する。
/// - timeoutとoutput budgetはrequest値を上流APIへ設定するhard limitとして扱う。delta累計や
///   完了resultが上限を超えた場合も共通continuationがfail-closedで終了する。
/// - 自動retry・fallbackを行わない。
public protocol AIProvider: Sendable {
    /// Previewとexecutor照合に使う、実行中に変化しないO(1)の不変stored descriptor。
    /// I/O、lock待機、actor hopを行うcomputed getterにしない。
    var descriptor: AIProviderDescriptor { get }

    func start(
        request: AIConfirmedRequest,
        events: AIProviderEventContinuation
    ) async
}
