import Foundation
@testable import NovelWriter
import Testing

@MainActor
struct EditorSettingsTests {
    @Test("未保存の幅設定は制限なしになる")
    func defaultWidthModeIsUnlimited() {
        let defaults = makeUserDefaults()
        let settings = EditorSettings(userDefaults: defaults)

        #expect(settings.widthMode == .unlimited)
    }

    @Test("保存済みの幅設定は維持される")
    func storedWidthModeIsPreserved() {
        let defaults = makeUserDefaults()
        defaults.set(EditorWidthMode.width900.rawValue, forKey: "dev.serikayuzuki.NovelWriter.editor.widthMode")

        let settings = EditorSettings(userDefaults: defaults)

        #expect(settings.widthMode == .width900)
    }

    @Test("保存済みフォントサイズは8...24へ正規化される")
    func storedFontSizeIsClamped() {
        let defaults = makeUserDefaults()
        defaults.set(30.0, forKey: "dev.serikayuzuki.NovelWriter.editor.fontSize")

        let settings = EditorSettings(userDefaults: defaults)

        #expect(settings.fontSize == 24)
        #expect(defaults.double(forKey: "dev.serikayuzuki.NovelWriter.editor.fontSize") == 24)
    }

    @Test("範囲外の下限フォントサイズも正規化される")
    func storedFontSizeClampsLowerBound() {
        let defaults = makeUserDefaults()
        defaults.set(6.0, forKey: "dev.serikayuzuki.NovelWriter.editor.fontSize")

        let settings = EditorSettings(userDefaults: defaults)

        #expect(settings.fontSize == 8)
    }

    private func makeUserDefaults() -> UserDefaults {
        let suiteName = "NovelWriterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
