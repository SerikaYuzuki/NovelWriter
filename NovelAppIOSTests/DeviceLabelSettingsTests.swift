import Foundation
@testable import FUMINIWAIOS
import NovelSyncV2Application
import Testing

@MainActor
struct DeviceLabelSettingsTests {
    @Test func isolatedDefaultsAreInjectedAndUpdateWithoutRestart() async throws {
        let suite = "DeviceLabelTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = DeviceLabelSettings.provider(defaults: defaults)
        #if os(iOS)
        #expect(["iPhone", "iPad"].contains(DeviceLabelSettings.defaultLabel))
        #else
        #expect(DeviceLabelSettings.defaultLabel == "Mac")
        #endif
        #expect(await provider() == DeviceLabelSettings.defaultLabel)
        defaults.set("仕事用Mac", forKey: DeviceLabel.defaultsKey)
        #expect(await provider() == "仕事用Mac")
        defaults.set("", forKey: DeviceLabel.defaultsKey)
        #expect(await provider() == DeviceLabelSettings.defaultLabel)
        defaults.set(DeviceLabel.setting(String(repeating: "名", count: 41)), forKey: DeviceLabel.defaultsKey)
        #expect(await provider()?.unicodeScalars.count == 40)
    }
}
