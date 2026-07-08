import EditorKit
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class EditorSettings {
    var fontSize: Double {
        didSet { userDefaults.set(fontSize, forKey: Self.fontSizeKey) }
    }

    var lineHeightMultiple: Double {
        didSet { userDefaults.set(lineHeightMultiple, forKey: Self.lineHeightKey) }
    }

    var widthMode: EditorWidthMode {
        didSet { userDefaults.set(widthMode.rawValue, forKey: Self.widthModeKey) }
    }

    private let userDefaults: UserDefaults

    private static let fontSizeKey = "dev.serikayuzuki.NovelWriter.editor.fontSize"
    private static let lineHeightKey = "dev.serikayuzuki.NovelWriter.editor.lineHeight"
    private static let widthModeKey = "dev.serikayuzuki.NovelWriter.editor.widthMode"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        let storedFontSize = userDefaults.double(forKey: Self.fontSizeKey)
        fontSize = storedFontSize == 0 ? 16 : storedFontSize

        let storedLineHeight = userDefaults.double(forKey: Self.lineHeightKey)
        lineHeightMultiple = storedLineHeight == 0 ? 1.5 : storedLineHeight

        let storedWidthMode = userDefaults.string(forKey: Self.widthModeKey) ?? ""
        widthMode = EditorWidthMode(rawValue: storedWidthMode) ?? .width900
    }

    var configuration: EditorConfiguration {
        EditorConfiguration(
            fontSize: fontSize,
            lineHeightMultiple: lineHeightMultiple
        )
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

struct EditorSettingsView: View {
    @Environment(EditorSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Slider(value: $settings.fontSize, in: 12 ... 24, step: 1) {
                Text("フォントサイズ")
            } minimumValueLabel: {
                Text("12")
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
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 420)
    }
}
