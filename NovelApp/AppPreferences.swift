import Foundation

/// ふみにわ固有の設定キーと、旧製品名からの一度限りの移行を集約する。
///
/// `.novelpkg`や作品の実ファイルは移動しない。旧domainから許可した設定だけを
/// 新domainへコピーし、既に新しい値がある場合は上書きしない(D-038)。
enum AppPreferenceKey {
    static let recentDocumentPath = "dev.serikayuzuki.fuminiwa.recentDocumentPath"
    static let projectSection = "dev.serikayuzuki.fuminiwa.projectSection"
    static let editorFontName = "dev.serikayuzuki.fuminiwa.editor.fontName"
    static let editorFontSize = "dev.serikayuzuki.fuminiwa.editor.fontSize"
    static let editorLineHeight = "dev.serikayuzuki.fuminiwa.editor.lineHeight"
    static let editorWidthMode = "dev.serikayuzuki.fuminiwa.editor.widthMode"
    static let editorTextColor = "dev.serikayuzuki.fuminiwa.editor.textColor"
    static let editorBackgroundColor = "dev.serikayuzuki.fuminiwa.editor.backgroundColor"
    static let preferenceMigrationVersion = "dev.serikayuzuki.fuminiwa.preferenceMigrationVersion"
}

enum LegacyPreferenceMigration {
    static let legacyBundleIdentifier = "dev.serikayuzuki.NovelWriter"
    static let currentVersion = 1

    private static let keyMappings: [(legacy: String, current: String)] = [
        ("dev.serikayuzuki.NovelWriter.recentDocumentPath", AppPreferenceKey.recentDocumentPath),
        ("dev.serikayuzuki.NovelWriter.projectSection", AppPreferenceKey.projectSection),
        ("dev.serikayuzuki.NovelWriter.editor.fontName", AppPreferenceKey.editorFontName),
        ("dev.serikayuzuki.NovelWriter.editor.fontSize", AppPreferenceKey.editorFontSize),
        ("dev.serikayuzuki.NovelWriter.editor.lineHeight", AppPreferenceKey.editorLineHeight),
        ("dev.serikayuzuki.NovelWriter.editor.widthMode", AppPreferenceKey.editorWidthMode),
        ("dev.serikayuzuki.NovelWriter.editor.textColor", AppPreferenceKey.editorTextColor),
        ("dev.serikayuzuki.NovelWriter.editor.backgroundColor", AppPreferenceKey.editorBackgroundColor)
    ]

    /// - Parameter legacyDomain: テスト用の旧domain注入。`nil`なら実際の旧bundle domainを読む。
    static func migrateIfNeeded(
        to destination: UserDefaults,
        legacyDomain: [String: Any]? = nil
    ) {
        guard destination.integer(forKey: AppPreferenceKey.preferenceMigrationVersion) < currentVersion else {
            return
        }

        let persistedLegacyDomain = legacyDomain
            ?? destination.persistentDomain(forName: legacyBundleIdentifier)
            ?? [:]

        for mapping in keyMappings where destination.object(forKey: mapping.current) == nil {
            // 同じdomain内に旧キーが残るdevelopment buildも移行対象にする。
            if let value = destination.object(forKey: mapping.legacy) ?? persistedLegacyDomain[mapping.legacy] {
                destination.set(value, forKey: mapping.current)
            }
        }

        destination.set(currentVersion, forKey: AppPreferenceKey.preferenceMigrationVersion)
    }
}
