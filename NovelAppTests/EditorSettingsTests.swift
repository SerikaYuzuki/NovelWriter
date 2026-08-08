import AppKit
import Foundation
@testable import FUMINIWA
import Testing

@MainActor
struct EditorSettingsTests {
    @Test("未保存の幅設定は制限なしになる")
    func defaultWidthModeIsUnlimited() {
        let defaults = makeUserDefaults()
        let settings = makeSettings(userDefaults: defaults)

        #expect(settings.widthMode == .unlimited)
    }

    @Test("保存済みの幅設定は維持される")
    func storedWidthModeIsPreserved() {
        let defaults = makeUserDefaults()
        defaults.set(EditorWidthMode.width900.rawValue, forKey: AppPreferenceKey.editorWidthMode)

        let settings = makeSettings(userDefaults: defaults)

        #expect(settings.widthMode == .width900)
    }

    @Test("未保存の外観設定はシステムに合わせるになる")
    func defaultAppearanceFollowsSystem() {
        let defaults = makeUserDefaults()
        let settings = makeSettings(userDefaults: defaults)

        #expect(settings.appearance == .system)
        #expect(settings.appearance.applicationAppearance == nil)
    }

    @Test("保存済みの外観設定は復元される")
    func storedAppearanceIsPreserved() {
        let defaults = makeUserDefaults()
        defaults.set(AppAppearance.light.rawValue, forKey: AppPreferenceKey.appearance)

        let settings = makeSettings(userDefaults: defaults)

        #expect(settings.appearance == .light)
        #expect(settings.appearance.applicationAppearance?.name == .aqua)
    }

    @Test("外観設定の変更は永続化される")
    func appearanceChangeIsPersisted() {
        let defaults = makeUserDefaults()
        let settings = makeSettings(userDefaults: defaults)

        settings.appearance = .dark

        #expect(defaults.string(forKey: AppPreferenceKey.appearance) == AppAppearance.dark.rawValue)
    }

    @Test("未知の外観設定はシステムに合わせるへ安全に戻る")
    func unknownAppearanceFallsBackToSystem() {
        let defaults = makeUserDefaults()
        defaults.set("future-appearance", forKey: AppPreferenceKey.appearance)

        let settings = makeSettings(userDefaults: defaults)

        #expect(settings.appearance == .system)
        #expect(settings.appearance.applicationAppearance == nil)
    }

    @Test("外観設定はAppKitの標準外観へ写像される")
    func appearanceMapsToStandardAppKitAppearances() {
        #expect(AppAppearance.system.applicationAppearance == nil)
        #expect(AppAppearance.light.applicationAppearance?.name == .aqua)
        #expect(AppAppearance.dark.applicationAppearance?.name == .darkAqua)
    }

    @Test("アプリ外観は本文キャンバス設定を変更しない")
    func appearanceIsIndependentFromEditorConfiguration() {
        let defaults = makeUserDefaults()
        let settings = makeSettings(userDefaults: defaults)
        let initialConfiguration = settings.configuration

        settings.appearance = .light

        #expect(settings.configuration == initialConfiguration)
    }

    @Test("起動時と変更時の外観同期はSystemで明示overrideを解除する")
    func appearanceSyncReleasesApplicationOverrideForSystem() {
        let defaults = makeUserDefaults()
        defaults.set(AppAppearance.light.rawValue, forKey: AppPreferenceKey.appearance)
        var appliedAppearances: [AppAppearance] = []
        let settings = EditorSettings(
            userDefaults: defaults,
            appearanceApplier: { appliedAppearances.append($0) }
        )

        settings.appearance = .system

        #expect(appliedAppearances == [.light, .system])
        #expect(appliedAppearances.last?.applicationAppearance == nil)
    }

    @Test("アプリ外観同期はNSApplicationのoverrideをnilへ戻せる")
    func applicationAppearanceCanReturnToSystem() {
        let previousAppearance = NSApplication.shared.appearance
        defer { NSApplication.shared.appearance = previousAppearance }

        AppAppearance.light.applyToApplication()
        #expect(NSApplication.shared.appearance?.name == .aqua)

        AppAppearance.system.applyToApplication()
        #expect(NSApplication.shared.appearance == nil)
    }

    @Test("保存済みフォントサイズは8...24へ正規化される")
    func storedFontSizeIsClamped() {
        let defaults = makeUserDefaults()
        defaults.set(30.0, forKey: AppPreferenceKey.editorFontSize)

        let settings = makeSettings(userDefaults: defaults)

        #expect(settings.fontSize == 24)
        #expect(defaults.double(forKey: AppPreferenceKey.editorFontSize) == 24)
    }

    @Test("範囲外の下限フォントサイズも正規化される")
    func storedFontSizeClampsLowerBound() {
        let defaults = makeUserDefaults()
        defaults.set(6.0, forKey: AppPreferenceKey.editorFontSize)

        let settings = makeSettings(userDefaults: defaults)

        #expect(settings.fontSize == 8)
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "FUMINIWATests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeSettings(userDefaults: UserDefaults) -> EditorSettings {
        EditorSettings(userDefaults: userDefaults, appearanceApplier: { _ in })
    }
}
