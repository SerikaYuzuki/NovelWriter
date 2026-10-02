import EditorKit
import Foundation
import NovelUI
import Observation
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

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

    var animatesCaret: Bool {
        didSet { userDefaults.set(animatesCaret, forKey: AppPreferenceKey.editorAnimatesCaret) }
    }

    let userDefaults: UserDefaults
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
        animatesCaret = userDefaults.object(forKey: AppPreferenceKey.editorAnimatesCaret) as? Bool ?? true

        self.appearanceApplier(appearance)
    }

    var configuration: EditorConfiguration {
        EditorConfiguration(
            fontName: fontName,
            fontSize: fontSize,
            lineHeightMultiple: lineHeightMultiple,
            textColorHex: textColorHex,
            backgroundColorHex: backgroundColorHex,
            animatesCaret: animatesCaret
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
    @State private var showingAssistantSettings = false

    var body: some View {
        @Bindable var settings = settings

        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.group) {
                settingsCard("外観") {
                    Picker("外観", selection: $settings.appearance) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.title)
                                .tag(appearance)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                settingsCard("本文") {
                    Picker("フォント", selection: fontFamilyBinding) {
                        ForEach(EditorFontFamily.allCases) { family in
                            Text(family.title)
                                .tag(family)
                        }
                    }
                    .pickerStyle(.menu)

                    LabeledContent("フォントサイズ") {
                        HStack {
                            Slider(value: $settings.fontSize, in: EditorSettings.fontSizeRange, step: 1)
                                .accessibilityLabel("フォントサイズ")
                            Text("\(Int(settings.fontSize)) pt")
                                .monospacedDigit()
                                .frame(minWidth: 48, alignment: .trailing)
                        }
                    }
                    LabeledContent("行間") {
                        HStack {
                            Slider(value: $settings.lineHeightMultiple, in: 1.2 ... 2.0, step: 0.1)
                                .accessibilityLabel("行間")
                            Text(String(format: "%.1f", settings.lineHeightMultiple))
                                .monospacedDigit()
                                .frame(minWidth: 48, alignment: .trailing)
                        }
                    }

                    Picker("本文の最大幅", selection: $settings.widthMode) {
                        ForEach(EditorWidthMode.allCases) { mode in
                            Text(mode.title)
                                .monospacedDigit()
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    #if canImport(AppKit)
                    Toggle("滑らかなカーソル", isOn: $settings.animatesCaret)
                        .accessibilityIdentifier("editor.animates-caret")
                    ColorPicker("本文色", selection: textColorBinding, supportsOpacity: false)
                    ColorPicker("背景色", selection: backgroundColorBinding, supportsOpacity: false)
                    #endif
                    Text("窓辺に、一冊の本を開く。")
                        .font(.custom(settings.fontName, size: settings.fontSize, relativeTo: .body))
                        .foregroundStyle(Color(hex: settings.textColorHex) ?? .primary)
                        .padding(Spacing.group)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(hex: settings.backgroundColorHex) ?? FuminiwaColor.paper.color)
                        .accessibilityLabel("本文のプレビュー。窓辺に、一冊の本を開く。")
                }
                settingsCard("AI支援") {
                    Button("AI支援の設定…") { showingAssistantSettings = true }
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .background(FuminiwaColor.paper.color)
        .sheet(isPresented: $showingAssistantSettings) {
            VStack {
                AssistantSettingsView(defaults: settings.userDefaults)
                Button("閉じる") { showingAssistantSettings = false }.padding()
            }.frame(width: 520, height: 620)
        }
    }

    private func settingsCard(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            Text(title).font(.headline)
            content()
        }
        .padding(Spacing.group)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FuminiwaColor.surface.color, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
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
