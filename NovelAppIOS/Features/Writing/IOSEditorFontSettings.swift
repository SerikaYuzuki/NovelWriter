import EditorKit
import Foundation

enum IOSEditorFontFamily: String, CaseIterable, Identifiable {
    case hiraginoMincho
    case hiraginoSans
    case system

    static let defaultValue = IOSEditorFontFamily.hiraginoMincho

    init(storedRawValue: String?) {
        self = storedRawValue.flatMap(Self.init(rawValue:)) ?? Self.defaultValue
    }

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .hiraginoMincho:
            "ヒラギノ明朝"
        case .hiraginoSans:
            "ヒラギノ角ゴ"
        case .system:
            "システム"
        }
    }

    var fontName: String {
        switch self {
        case .hiraginoMincho:
            "HiraMinProN-W3"
        case .hiraginoSans:
            "HiraginoSans-W3"
        case .system:
            ".AppleSystemUIFont"
        }
    }
}

enum IOSEditorFontPreference {
    static let preferenceKey = "dev.serikayuzuki.fuminiwa.ios.editor.fontFamily"
    static let initialRawValue = IOSEditorFontFamily.defaultValue.rawValue

    static func configuration(storedRawValue: String?) -> EditorConfiguration {
        EditorConfiguration(fontName: IOSEditorFontFamily(storedRawValue: storedRawValue).fontName)
    }
}
