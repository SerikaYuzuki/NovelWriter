import Foundation

/// Device-only startup settings. Never encoded into manuscript/sync data.
public struct FuminiwaTiming: Equatable, Sendable {
    public enum Key {
        public static let autosaveDebounce = "fuminiwa.timing.autosaveDebounceSeconds"
        public static let autosavePostSaveWait = "fuminiwa.timing.autosavePostSaveWaitSeconds"
        public static let writingSyncVisible = "fuminiwa.timing.writingSyncVisibleSeconds"
        public static let writingSyncHidden = "fuminiwa.timing.writingSyncHiddenSeconds"
        public static let writingSyncRetryInitial = "fuminiwa.timing.writingSyncRetryInitialSeconds"
        public static let writingSyncRetryMaximum = "fuminiwa.timing.writingSyncRetryMaximumSeconds"
        public static let progressPublish = "fuminiwa.timing.progressPublishSeconds"
        public static let promotionIdle = "fuminiwa.timing.promotionIdleSeconds"
        public static let promotionMaximum = "fuminiwa.timing.promotionMaximumSeconds"
        public static let headPollNormal = "fuminiwa.timing.headPollNormalSeconds"
        public static let headPollTyping = "fuminiwa.timing.headPollTypingSeconds"
        public static let headPollFailure = "fuminiwa.timing.headPollFailureSeconds"
        public static let headPollTypingWindow = "fuminiwa.timing.headPollTypingWindowSeconds"
        public static let sendRetryInitial = "fuminiwa.timing.sendRetryInitialSeconds"
        public static let sendRetryMaximum = "fuminiwa.timing.sendRetryMaximumSeconds"
    }

    public let autosaveDebounceSeconds: Double
    public let autosavePostSaveWaitSeconds: Double
    public let writingSyncVisibleSeconds: Double
    public let writingSyncHiddenSeconds: Double
    public let writingSyncRetryInitialSeconds: Double
    public let writingSyncRetryMaximumSeconds: Double
    public let progressPublishSeconds: Double

    public let promotionIdleSeconds: Double
    public let promotionMaximumSeconds: Double
    public let headPollNormalSeconds: Double
    public let headPollTypingSeconds: Double
    public let headPollFailureSeconds: Double
    public let headPollTypingWindowSeconds: Double
    public let sendRetryInitialSeconds: Double
    public let sendRetryMaximumSeconds: Double

    public init(
        autosaveDebounceSeconds: Double = 2,
        autosavePostSaveWaitSeconds: Double = 2,
        writingSyncVisibleSeconds: Double = 10,
        writingSyncHiddenSeconds: Double = 300,
        writingSyncRetryInitialSeconds: Double = 20,
        writingSyncRetryMaximumSeconds: Double = 600,
        progressPublishSeconds: Double = 3,
        promotionIdleSeconds: Double = 60,
        promotionMaximumSeconds: Double = 300,
        headPollNormalSeconds: Double = 10,
        headPollTypingSeconds: Double = 120,
        headPollFailureSeconds: Double = 60,
        headPollTypingWindowSeconds: Double = 60,
        sendRetryInitialSeconds: Double = 2,
        sendRetryMaximumSeconds: Double = 60
    ) {
        self.autosaveDebounceSeconds = Self.clamp(autosaveDebounceSeconds, fallback: 2, range: 0.25 ... 60)
        self.autosavePostSaveWaitSeconds = Self.clamp(autosavePostSaveWaitSeconds, fallback: 2, range: 0.25 ... 60)
        self.writingSyncVisibleSeconds = Self.clamp(writingSyncVisibleSeconds, fallback: 10, range: 1 ... 600)
        self.writingSyncHiddenSeconds = Self.clamp(writingSyncHiddenSeconds, fallback: 300, range: 5 ... 3600)
        self.writingSyncRetryInitialSeconds = Self.clamp(writingSyncRetryInitialSeconds, fallback: 20, range: 1 ... 600)
        self.writingSyncRetryMaximumSeconds = max(
            self.writingSyncRetryInitialSeconds,
            Self.clamp(writingSyncRetryMaximumSeconds, fallback: 600, range: 1 ... 3600)
        )
        self.progressPublishSeconds = Self.clamp(progressPublishSeconds, fallback: 3, range: 0.1 ... 60)
        self.promotionIdleSeconds = Self.clamp(promotionIdleSeconds, fallback: 60, range: 1 ... 600)
        let promotionMaximum = Self.clamp(promotionMaximumSeconds, fallback: 300, range: 1 ... 3600)
        self.headPollNormalSeconds = Self.clamp(headPollNormalSeconds, fallback: 10, range: 1 ... 600)
        self.headPollTypingSeconds = Self.clamp(headPollTypingSeconds, fallback: 120, range: 1 ... 3600)
        self.headPollFailureSeconds = Self.clamp(headPollFailureSeconds, fallback: 60, range: 1 ... 3600)
        self.headPollTypingWindowSeconds = Self.clamp(headPollTypingWindowSeconds, fallback: 60, range: 1 ... 600)
        self.sendRetryInitialSeconds = Self.clamp(sendRetryInitialSeconds, fallback: 2, range: 0.25 ... 60)
        let sendRetryMaximum = Self.clamp(sendRetryMaximumSeconds, fallback: 60, range: 0.25 ... 600)
        self.promotionMaximumSeconds = max(self.promotionIdleSeconds, promotionMaximum)
        self.sendRetryMaximumSeconds = max(self.sendRetryInitialSeconds, sendRetryMaximum)
    }

    private static func clamp(_ value: Double, fallback: Double, range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}
