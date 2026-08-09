import Foundation

#if !FUMINIWA_ENABLE_EXPERIMENTAL_AI
#error("Codex synthetic interactive transport must only compile in FUMINIWAExperimental")
#endif

enum CodexSyntheticOpenOutcome: Sendable {
    case opened(any CodexSyntheticInteractiveChannel)
    case failed
    case stopped(CodexSyntheticInteractiveStopReason)
}

final class CodexSyntheticOpenRace: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: CodexSyntheticOpenOutcome?
    private var continuation: CheckedContinuation<CodexSyntheticOpenOutcome, Never>?

    func wait() async -> CodexSyntheticOpenOutcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(returning: outcome)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    @discardableResult
    func resolve(_ outcome: CodexSyntheticOpenOutcome) -> Bool {
        let continuation: CheckedContinuation<CodexSyntheticOpenOutcome, Never>?
        lock.lock()
        guard self.outcome == nil else {
            lock.unlock()
            return false
        }
        self.outcome = outcome
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: outcome)
        return true
    }
}
