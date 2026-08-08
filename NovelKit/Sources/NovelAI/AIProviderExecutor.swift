/// request/provider照合とstream生成をadapterの外側で所有する実行境界。
///
/// Adapterは比較に使うdescriptorを選べず、不一致の場合は`start`自体を呼ばない。
/// 最初の呼出しがconfirmationを消費し、その後のcancel／timeout／照合失敗でも再利用しない。
public enum AIProviderExecutor {
    public static func events(
        for request: AIConfirmedRequest,
        using provider: some AIProvider
    ) -> AIProviderEventStream {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(
            by: .seconds(request.outbound.budget.timeoutSeconds)
        )
        return events(for: request, using: provider, deadline: deadline)
    }

    /// Public entryで確定したdeadlineを、lease取得やdescriptor照合の後に延長しない。
    static func events(
        for request: AIConfirmedRequest,
        using provider: some AIProvider,
        deadline: ContinuousClock.Instant
    ) -> AIProviderEventStream {
        guard request.claimExecution() else {
            return terminalStream(for: request, error: .confirmationAlreadyUsed)
        }
        guard !Task.isCancelled else {
            return terminalStream(for: request, error: .cancelled)
        }
        let descriptor = provider.descriptor
        guard !Task.isCancelled else {
            return terminalStream(for: request, error: .cancelled)
        }
        let remaining = ContinuousClock().now.duration(to: deadline)
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
