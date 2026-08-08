import Foundation

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
}

public extension AIProviderEventContinuation {
    func yieldStarted() {
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

    func yieldReplacementDelta(_ delta: String) {
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

        switch accumulatedDeltaCounts(adding: delta) {
        case let .success(counts):
            deltaCharacterCount = counts.characters
            deltaUTF8ByteCount = counts.utf8Bytes
            continuation.yield(.replacementDelta(delta))
            lock.unlock()
        case let .failure(error):
            let cancellationHandler = finishLocked(
                with: .failed(error),
                cancelUpstream: true
            )
            lock.unlock()
            cancellationHandler?()
        }
    }
}

public extension AIProviderEventContinuation {
    /// Providerのraw structured outputをdomainのbyte上限・exact schema・usage budgetで検証して完了する。
    /// AdapterはSDKがdecodeした任意の値から`AIResult`を直接構築して、この境界を迂回できない。
    func complete(structuredOutput: String, usage: AIUsage) {
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

    func fail(_ error: AIError) {
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
    func onUpstreamCancellation(_ handler: @escaping @Sendable () -> Void) {
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
}

extension AIProviderEventContinuation {
    func consumerCancelled() {
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

    func armTimeout() {
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
}

private extension AIProviderEventContinuation {
    struct DeltaCounts {
        let characters: Int
        let utf8Bytes: Int
    }

    func accumulatedDeltaCounts(adding delta: String) -> Result<DeltaCounts, AIError> {
        let characterAddition = deltaCharacterCount.addingReportingOverflow(delta.count)
        let characters = characterAddition.overflow ? Int.max : characterAddition.partialValue
        let exceedsCharacterLimit = characterAddition.overflow ||
            characters > request.outbound.budget.maximumOutputCharacters
        guard !exceedsCharacterLimit else {
            return .failure(
                .outputCharacterLimitExceeded(
                    limit: request.outbound.budget.maximumOutputCharacters,
                    actual: characters
                )
            )
        }

        let byteAddition = deltaUTF8ByteCount.addingReportingOverflow(delta.utf8.count)
        let utf8Bytes = byteAddition.overflow ? Int.max : byteAddition.partialValue
        let exceedsByteLimit = byteAddition.overflow ||
            utf8Bytes > request.outbound.budget.maximumOutputUTF8Bytes
        guard !exceedsByteLimit else {
            return .failure(
                .outputUTF8ByteLimitExceeded(
                    limit: request.outbound.budget.maximumOutputUTF8Bytes,
                    actual: utf8Bytes
                )
            )
        }

        return .success(DeltaCounts(characters: characters, utf8Bytes: utf8Bytes))
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
