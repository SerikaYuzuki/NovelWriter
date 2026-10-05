import Foundation
import NovelTiming
@testable import NovelWorkspace
import Testing

struct FuminiwaTimingDefaultsTests {
    private struct Setting {
        let key: String
        let path: KeyPath<FuminiwaTiming, Double>
        let fallback: Double
        let range: ClosedRange<Double>
    }

    private var settings: [Setting] {
        [
            .init(
                key: FuminiwaTiming.Key.autosaveDebounce,
                path: \.autosaveDebounceSeconds,
                fallback: 2,
                range: 0.25 ... 60
            ),
            .init(
                key: FuminiwaTiming.Key.autosavePostSaveWait,
                path: \.autosavePostSaveWaitSeconds,
                fallback: 2,
                range: 0.25 ... 60
            ),
            .init(
                key: FuminiwaTiming.Key.writingSyncVisible,
                path: \.writingSyncVisibleSeconds,
                fallback: 10,
                range: 1 ... 600
            ),
            .init(
                key: FuminiwaTiming.Key.writingSyncHidden,
                path: \.writingSyncHiddenSeconds,
                fallback: 300,
                range: 5 ... 3600
            ),
            .init(
                key: FuminiwaTiming.Key.writingSyncRetryInitial,
                path: \.writingSyncRetryInitialSeconds,
                fallback: 20,
                range: 1 ... 600
            ),
            .init(
                key: FuminiwaTiming.Key.writingSyncRetryMaximum,
                path: \.writingSyncRetryMaximumSeconds,
                fallback: 600,
                range: 1 ... 3600
            ),
            .init(key: FuminiwaTiming.Key.promotionIdle, path: \.promotionIdleSeconds, fallback: 60, range: 1 ... 600),
            .init(key: FuminiwaTiming.Key.promotionMaximum, path: \.promotionMaximumSeconds, fallback: 300, range: 1 ... 3600),
            .init(key: FuminiwaTiming.Key.headPollNormal, path: \.headPollNormalSeconds, fallback: 10, range: 1 ... 600),
            .init(key: FuminiwaTiming.Key.headPollTyping, path: \.headPollTypingSeconds, fallback: 120, range: 1 ... 3600),
            .init(key: FuminiwaTiming.Key.headPollFailure, path: \.headPollFailureSeconds, fallback: 60, range: 1 ... 3600),
            .init(key: FuminiwaTiming.Key.headPollTypingWindow, path: \.headPollTypingWindowSeconds, fallback: 60, range: 1 ... 600),
            .init(key: FuminiwaTiming.Key.sendRetryInitial, path: \.sendRetryInitialSeconds, fallback: 2, range: 0.25 ... 60),
            .init(key: FuminiwaTiming.Key.sendRetryMaximum, path: \.sendRetryMaximumSeconds, fallback: 60, range: 0.25 ... 600),
            .init(
                key: FuminiwaTiming.Key.progressPublish,
                path: \.progressPublishSeconds,
                fallback: 3,
                range: 0.1 ... 60
            )
        ]
    }

    @Test func defaultsOverridesClampsAndMalformedValues() throws {
        let suite = "fuminiwa-timing-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for setting in settings {
            let key = setting.key, path = setting.path, fallback = setting.fallback
            let lower = setting.range.lowerBound, upper = setting.range.upperBound
            #expect(FuminiwaTiming(defaults: defaults)[keyPath: path] == fallback)
            defaults.set(fallback + 0.5, forKey: key)
            #expect(FuminiwaTiming(defaults: defaults)[keyPath: path] == fallback + 0.5)
            defaults.set(String(fallback + 0.25), forKey: key)
            #expect(FuminiwaTiming(defaults: defaults)[keyPath: path] == fallback + 0.25)
            for value in [-1.0, 0.0, -Double.greatestFiniteMagnitude] {
                defaults.set(value, forKey: key)
                // Maximum retry is also bounded below by the initial retry.
                let expected: Double = switch key {
                case FuminiwaTiming.Key.writingSyncRetryMaximum: 20
                case FuminiwaTiming.Key.promotionMaximum: 60
                case FuminiwaTiming.Key.sendRetryMaximum: 2
                default: lower
                }
                #expect(FuminiwaTiming(defaults: defaults)[keyPath: path] == expected)
            }
            defaults.set(Double.greatestFiniteMagnitude, forKey: key)
            #expect(FuminiwaTiming(defaults: defaults)[keyPath: path] == upper)
            for value in ["bad", "nan", "inf"] {
                defaults.set(value, forKey: key)
                #expect(FuminiwaTiming(defaults: defaults)[keyPath: path] == fallback)
            }
            defaults.set(false, forKey: key)
            #expect(FuminiwaTiming(defaults: defaults)[keyPath: path] == fallback)
            defaults.removeObject(forKey: key)
        }
    }

    @Test func settingsAreAnImmutableStartupSnapshot() throws {
        let suite = "fuminiwa-timing-snapshot-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(4, forKey: FuminiwaTiming.Key.autosaveDebounce)
        let timing = FuminiwaTiming(defaults: defaults)
        defaults.set(6, forKey: FuminiwaTiming.Key.autosaveDebounce)
        #expect(timing.autosaveDebounceSeconds == 4)
        #expect(FuminiwaTiming(defaults: defaults).autosaveDebounceSeconds == 6)
        let nonFinite = FuminiwaTiming(autosaveDebounceSeconds: .nan, autosavePostSaveWaitSeconds: .infinity)
        #expect(nonFinite.autosaveDebounceSeconds == 2)
        #expect(nonFinite.autosavePostSaveWaitSeconds == 2)
        #expect(FuminiwaTiming(writingSyncRetryInitialSeconds: 90, writingSyncRetryMaximumSeconds: 1)
            .writingSyncRetryMaximumSeconds == 90)
    }
}
