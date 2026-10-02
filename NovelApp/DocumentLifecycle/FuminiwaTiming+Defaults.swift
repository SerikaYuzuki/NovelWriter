import CoreFoundation
import Foundation
import NovelTiming

/// Read once in the application composition; NovelKit receives only values.
extension FuminiwaTiming {
    init(defaults: UserDefaults) {
        let standard = FuminiwaTiming()
        self.init(
            autosaveDebounceSeconds: Self.read(defaults, Key.autosaveDebounce, fallback: standard.autosaveDebounceSeconds),
            autosavePostSaveWaitSeconds: Self.read(defaults, Key.autosavePostSaveWait, fallback: standard.autosavePostSaveWaitSeconds),
            writingSyncVisibleSeconds: Self.read(defaults, Key.writingSyncVisible, fallback: standard.writingSyncVisibleSeconds),
            writingSyncHiddenSeconds: Self.read(defaults, Key.writingSyncHidden, fallback: standard.writingSyncHiddenSeconds),
            writingSyncRetryInitialSeconds: Self.read(defaults, Key.writingSyncRetryInitial, fallback: standard.writingSyncRetryInitialSeconds),
            writingSyncRetryMaximumSeconds: Self.read(defaults, Key.writingSyncRetryMaximum, fallback: standard.writingSyncRetryMaximumSeconds),
            progressPublishSeconds: Self.read(defaults, Key.progressPublish, fallback: standard.progressPublishSeconds),
            promotionIdleSeconds: Self.read(defaults, Key.promotionIdle, fallback: standard.promotionIdleSeconds),
            promotionMaximumSeconds: Self.read(defaults, Key.promotionMaximum, fallback: standard.promotionMaximumSeconds),
            headPollNormalSeconds: Self.read(defaults, Key.headPollNormal, fallback: standard.headPollNormalSeconds),
            headPollTypingSeconds: Self.read(defaults, Key.headPollTyping, fallback: standard.headPollTypingSeconds),
            headPollFailureSeconds: Self.read(defaults, Key.headPollFailure, fallback: standard.headPollFailureSeconds),
            headPollTypingWindowSeconds: Self.read(defaults, Key.headPollTypingWindow, fallback: standard.headPollTypingWindowSeconds),
            sendRetryInitialSeconds: Self.read(defaults, Key.sendRetryInitial, fallback: standard.sendRetryInitialSeconds),
            sendRetryMaximumSeconds: Self.read(defaults, Key.sendRetryMaximum, fallback: standard.sendRetryMaximumSeconds)
        )
    }

    private static func read(_ defaults: UserDefaults, _ key: String, fallback: Double) -> Double {
        let value = defaults.object(forKey: key)
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.doubleValue
        }
        // Xcode Scheme / simctl launch arguments populate NSArgumentDomain as strings.
        if let string = value as? String, let number = Double(string) {
            return number
        }
        return fallback
    }
}
