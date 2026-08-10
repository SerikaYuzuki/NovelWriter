@testable import FUMINIWAIOS
import SwiftUI
import Testing

@Suite("iOS app appearance")
struct IOSAppearanceTests {
    @Test("初回の外観はダークになる")
    func initialAppearanceIsDark() {
        #expect(IOSAppearance.initialRawValue == IOSAppearance.dark.rawValue)
        #expect(IOSAppearance(storedRawValue: nil) == .dark)
    }

    @Test("保存済みの外観raw valueを復元する")
    func storedRawValuesAreRestored() {
        for appearance in IOSAppearance.allCases {
            #expect(IOSAppearance(storedRawValue: appearance.rawValue) == appearance)
        }
    }

    @Test("未知の保存値はシステムに合わせるへ戻る")
    func unknownStoredValueFallsBackToSystem() {
        #expect(IOSAppearance(storedRawValue: "future-appearance") == .system)
        #expect(IOSAppearance(storedRawValue: "") == .system)
    }

    @Test("外観はSwiftUIの標準ColorSchemeへ写像される")
    func appearanceMapsToColorScheme() {
        #expect(IOSAppearance.system.colorScheme == nil)
        #expect(IOSAppearance.light.colorScheme == ColorScheme.light)
        #expect(IOSAppearance.dark.colorScheme == ColorScheme.dark)
    }

    @Test("外観ラベルとアイコンを提供する")
    func appearanceProvidesLabelsAndIcons() {
        #expect(IOSAppearance.system.title == "システムに合わせる")
        #expect(IOSAppearance.light.title == "ライト")
        #expect(IOSAppearance.dark.title == "ダーク")
        #expect(IOSAppearance.system.systemImage == "circle.lefthalf.filled")
        #expect(IOSAppearance.light.systemImage == "sun.max")
        #expect(IOSAppearance.dark.systemImage == "moon.fill")
    }

    @Test("UserDefaultsへraw valueを保存して復元できる")
    func rawValueRoundTripsThroughUserDefaults() throws {
        let suiteName = "dev.serikayuzuki.fuminiwa.ios.appearance-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        #expect(
            IOSAppearance(storedRawValue: defaults.string(forKey: IOSAppearance.preferenceKey)) == .dark
        )

        defaults.set(IOSAppearance.light.rawValue, forKey: IOSAppearance.preferenceKey)
        #expect(
            IOSAppearance(storedRawValue: defaults.string(forKey: IOSAppearance.preferenceKey)) == .light
        )

        defaults.set("future-appearance", forKey: IOSAppearance.preferenceKey)
        #expect(
            IOSAppearance(storedRawValue: defaults.string(forKey: IOSAppearance.preferenceKey)) == .system
        )
    }
}
