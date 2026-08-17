import Foundation
@testable import FUMINIWA
import Testing

struct LegacyPreferenceMigrationTests {
    @MainActor
    @Test("通常targetは旧設定移行と通常版保存rootを使う")
    func standardBuildFlavorKeepsLegacyMigrationAndDocumentRoot() {
        #expect(AppBuildFlavor.migratesLegacyPreferences)
        #expect(AppBuildFlavor.defaultDocumentDirectoryName == "FUMINIWA")
        #expect(
            AppDependencies(
                userDefaults: makeIsolatedTestUserDefaults()
            ).defaultDocumentDirectoryName == "FUMINIWA"
        )
    }

    @Test("旧製品の許可済み設定を新しいキーへ移行する")
    func migratesAllowlistedLegacyPreferences() throws {
        let defaults = try makeUserDefaults()
        let legacyPath = "/Users/example/Documents/NovelWriter/長編.novelpkg"
        let legacyDomain: [String: Any] = [
            "dev.serikayuzuki.NovelWriter.recentDocumentPath": legacyPath,
            "dev.serikayuzuki.NovelWriter.projectSection": "characters",
            "dev.serikayuzuki.NovelWriter.editor.fontName": "YuMincho",
            "dev.serikayuzuki.NovelWriter.editor.fontSize": 18.0,
            "dev.serikayuzuki.NovelWriter.editor.lineHeight": 1.8,
            "dev.serikayuzuki.NovelWriter.editor.widthMode": "width900",
            "dev.serikayuzuki.NovelWriter.editor.textColor": "#111111",
            "dev.serikayuzuki.NovelWriter.editor.backgroundColor": "#FAFAFA",
            "dev.serikayuzuki.NovelWriter.notAllowlisted": "コピーしない"
        ]

        LegacyPreferenceMigration.migrateIfNeeded(to: defaults, legacyDomain: legacyDomain)

        #expect(defaults.string(forKey: AppPreferenceKey.recentDocumentPath) == legacyPath)
        #expect(defaults.string(forKey: AppPreferenceKey.projectSection) == "characters")
        #expect(defaults.string(forKey: AppPreferenceKey.editorFontName) == "YuMincho")
        #expect(defaults.double(forKey: AppPreferenceKey.editorFontSize) == 18)
        #expect(defaults.double(forKey: AppPreferenceKey.editorLineHeight) == 1.8)
        #expect(defaults.string(forKey: AppPreferenceKey.editorWidthMode) == "width900")
        #expect(defaults.string(forKey: AppPreferenceKey.editorTextColor) == "#111111")
        #expect(defaults.string(forKey: AppPreferenceKey.editorBackgroundColor) == "#FAFAFA")
        #expect(defaults.object(forKey: "dev.serikayuzuki.fuminiwa.notAllowlisted") == nil)
    }

    @Test("新しい設定を旧domainで上書きせず移行は冪等")
    func preservesCurrentPreferencesAndIsIdempotent() throws {
        let defaults = try makeUserDefaults()
        defaults.set("plot", forKey: AppPreferenceKey.projectSection)

        LegacyPreferenceMigration.migrateIfNeeded(
            to: defaults,
            legacyDomain: ["dev.serikayuzuki.NovelWriter.projectSection": "characters"]
        )
        LegacyPreferenceMigration.migrateIfNeeded(
            to: defaults,
            legacyDomain: ["dev.serikayuzuki.NovelWriter.projectSection": "references"]
        )

        #expect(defaults.string(forKey: AppPreferenceKey.projectSection) == "plot")
        #expect(defaults.integer(forKey: AppPreferenceKey.preferenceMigrationVersion) == 1)
    }

    private func makeUserDefaults() throws -> UserDefaults {
        let suiteName = "FUMINIWALegacyMigration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
