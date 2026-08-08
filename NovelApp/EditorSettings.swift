import EditorKit
import Foundation
import Observation
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
import NovelUI

@MainActor
@Observable
final class EditorSettings {
    static let fontSizeRange = 8.0 ... 24.0
    static let defaultFontSize = 16.0

    var fontName: String {
        didSet { userDefaults.set(fontName, forKey: Self.fontNameKey) }
    }

    var fontSize: Double {
        didSet {
            let clamped = Self.clampedFontSize(fontSize)
            if clamped != fontSize {
                fontSize = clamped
            }
            userDefaults.set(fontSize, forKey: Self.fontSizeKey)
        }
    }

    var lineHeightMultiple: Double {
        didSet { userDefaults.set(lineHeightMultiple, forKey: Self.lineHeightKey) }
    }

    var widthMode: EditorWidthMode {
        didSet { userDefaults.set(widthMode.rawValue, forKey: Self.widthModeKey) }
    }

    var appearance: AppAppearance {
        didSet {
            userDefaults.set(appearance.rawValue, forKey: Self.appearanceKey)
            appearanceApplier(appearance)
        }
    }

    var textColorHex: String {
        didSet { userDefaults.set(textColorHex, forKey: Self.textColorKey) }
    }

    var backgroundColorHex: String {
        didSet { userDefaults.set(backgroundColorHex, forKey: Self.backgroundColorKey) }
    }

    private let userDefaults: UserDefaults
    private let appearanceApplier: @MainActor (AppAppearance) -> Void

    private static let fontNameKey = AppPreferenceKey.editorFontName
    private static let fontSizeKey = AppPreferenceKey.editorFontSize
    private static let lineHeightKey = AppPreferenceKey.editorLineHeight
    private static let widthModeKey = AppPreferenceKey.editorWidthMode
    private static let appearanceKey = AppPreferenceKey.appearance
    private static let textColorKey = AppPreferenceKey.editorTextColor
    private static let backgroundColorKey = AppPreferenceKey.editorBackgroundColor

    init(
        userDefaults: UserDefaults = .standard,
        appearanceApplier: (@MainActor (AppAppearance) -> Void)? = nil
    ) {
        self.userDefaults = userDefaults
        self.appearanceApplier = appearanceApplier ?? { appearance in
            appearance.applyToApplication()
        }

        fontName = userDefaults.string(forKey: Self.fontNameKey) ?? EditorFontFamily.hiraginoMincho.fontName

        let storedFontSize = userDefaults.double(forKey: Self.fontSizeKey)
        let normalizedFontSize = storedFontSize == 0 ? Self.defaultFontSize : Self.clampedFontSize(storedFontSize)
        fontSize = normalizedFontSize
        if storedFontSize != 0, storedFontSize != normalizedFontSize {
            userDefaults.set(normalizedFontSize, forKey: Self.fontSizeKey)
        }

        let storedLineHeight = userDefaults.double(forKey: Self.lineHeightKey)
        lineHeightMultiple = storedLineHeight == 0 ? 1.5 : storedLineHeight

        let storedWidthMode = userDefaults.string(forKey: Self.widthModeKey) ?? ""
        widthMode = EditorWidthMode(rawValue: storedWidthMode) ?? .unlimited

        let storedAppearance = userDefaults.string(forKey: Self.appearanceKey) ?? ""
        appearance = AppAppearance(rawValue: storedAppearance) ?? .system

        textColorHex = userDefaults.string(forKey: Self.textColorKey)
            ?? EditorConfiguration.defaultTextColorHex
        backgroundColorHex = userDefaults.string(forKey: Self.backgroundColorKey)
            ?? EditorConfiguration.defaultBackgroundColorHex

        self.appearanceApplier(appearance)
    }

    var configuration: EditorConfiguration {
        EditorConfiguration(
            fontName: fontName,
            fontSize: fontSize,
            lineHeightMultiple: lineHeightMultiple,
            textColorHex: textColorHex,
            backgroundColorHex: backgroundColorHex
        )
    }

    private static func clampedFontSize(_ value: Double) -> Double {
        min(max(value, fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }
}

enum EditorFontFamily: String, CaseIterable, Identifiable {
    case hiraginoMincho
    case hiraginoSans
    case yuMincho
    case system

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .hiraginoMincho:
            "ヒラギノ明朝"
        case .hiraginoSans:
            "ヒラギノ角ゴ"
        case .yuMincho:
            "游明朝"
        case .system:
            "システム"
        }
    }

    var fontName: String {
        switch self {
        case .hiraginoMincho:
            "Hiragino Mincho ProN"
        case .hiraginoSans:
            "Hiragino Sans"
        case .yuMincho:
            "YuMincho"
        case .system:
            ".AppleSystemUIFont"
        }
    }

    static func selection(for fontName: String) -> EditorFontFamily {
        allCases.first { $0.fontName == fontName } ?? .hiraginoMincho
    }
}

enum EditorWidthMode: String, CaseIterable, Identifiable {
    case unlimited
    case width700
    case width900

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .unlimited:
            "制限なし"
        case .width700:
            "700pt"
        case .width900:
            "900pt"
        }
    }

    var maximumContentWidth: Double? {
        switch self {
        case .unlimited:
            nil
        case .width700:
            700
        case .width900:
            900
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .system:
            "システムに合わせる"
        case .light:
            "ライト"
        case .dark:
            "ダーク"
        }
    }

    #if canImport(AppKit)
    var applicationAppearance: NSAppearance? {
        switch self {
        case .system:
            nil
        case .light:
            NSAppearance(named: .aqua)
        case .dark:
            NSAppearance(named: .darkAqua)
        }
    }

    @MainActor
    func applyToApplication() {
        NSApplication.shared.appearance = applicationAppearance
    }
    #else
    @MainActor
    func applyToApplication() {}
    #endif
}

struct EditorSettingsView: View {
    @Environment(EditorSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Picker("外観", selection: $settings.appearance) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.title)
                        .tag(appearance)
                }
            }
            .pickerStyle(.segmented)

            Picker("フォント", selection: fontFamilyBinding) {
                ForEach(EditorFontFamily.allCases) { family in
                    Text(family.title)
                        .tag(family)
                }
            }
            .pickerStyle(.menu)

            Slider(value: $settings.fontSize, in: EditorSettings.fontSizeRange, step: 1) {
                Text("フォントサイズ")
            } minimumValueLabel: {
                Text("8")
                    .monospacedDigit()
            } maximumValueLabel: {
                Text("24")
                    .monospacedDigit()
            }
            Text("\(Int(settings.fontSize)) pt")
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Slider(value: $settings.lineHeightMultiple, in: 1.2 ... 2.0, step: 0.1) {
                Text("行間")
            } minimumValueLabel: {
                Text("1.2")
                    .monospacedDigit()
            } maximumValueLabel: {
                Text("2.0")
                    .monospacedDigit()
            }
            Text(String(format: "%.1f", settings.lineHeightMultiple))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Picker("本文の最大幅", selection: $settings.widthMode) {
                ForEach(EditorWidthMode.allCases) { mode in
                    Text(mode.title)
                        .monospacedDigit()
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)

            #if canImport(AppKit)
            ColorPicker("本文色", selection: textColorBinding, supportsOpacity: false)
            ColorPicker("背景色", selection: backgroundColorBinding, supportsOpacity: false)
            #endif
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 420)
    }

    private var fontFamilyBinding: Binding<EditorFontFamily> {
        Binding(
            get: { EditorFontFamily.selection(for: settings.fontName) },
            set: { settings.fontName = $0.fontName }
        )
    }

    #if canImport(AppKit)
    private var textColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: settings.textColorHex) ?? Color(nsColor: .labelColor) },
            set: { color in
                settings.textColorHex = NSColor(color).hexString ?? EditorConfiguration.defaultTextColorHex
            }
        )
    }

    private var backgroundColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: settings.backgroundColorHex) ?? Color(nsColor: .textBackgroundColor) },
            set: { color in
                settings.backgroundColorHex = NSColor(color).hexString ?? EditorConfiguration.defaultBackgroundColorHex
            }
        )
    }
    #endif
}
