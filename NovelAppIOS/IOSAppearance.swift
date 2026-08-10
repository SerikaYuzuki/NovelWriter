import SwiftUI
import UIKit

enum IOSPalette {
    /// STYLEの`canvas`とEditorKit既定背景（#171719）を共有するiOS App側token。
    static let editorCanvas = Color(
        red: 23.0 / 255.0,
        green: 23.0 / 255.0,
        blue: 25.0 / 255.0
    )

    static let accent = Color(
        uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor(
                    red: 140.0 / 255.0,
                    green: 167.0 / 255.0,
                    blue: 223.0 / 255.0,
                    alpha: 1
                )
            }
            return UIColor(
                red: 52.0 / 255.0,
                green: 85.0 / 255.0,
                blue: 139.0 / 255.0,
                alpha: 1
            )
        }
    )
}

enum IOSAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let preferenceKey = "FUMINIWAIOS.appearance"
    static let initialRawValue = IOSAppearance.dark.rawValue

    init(storedRawValue: String?) {
        guard let storedRawValue else {
            self = .dark
            return
        }
        self = IOSAppearance(rawValue: storedRawValue) ?? .system
    }

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

    var systemImage: String {
        switch self {
        case .system:
            "circle.lefthalf.filled"
        case .light:
            "sun.max"
        case .dark:
            "moon.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

struct IOSAppearanceMenu: View {
    @AppStorage(IOSAppearance.preferenceKey)
    private var appearanceRawValue = IOSAppearance.initialRawValue

    var body: some View {
        Menu {
            Picker("外観", selection: appearanceBinding) {
                ForEach(IOSAppearance.allCases) { appearance in
                    Label(appearance.title, systemImage: appearance.systemImage)
                        .tag(appearance)
                }
            }
        } label: {
            Label("外観", systemImage: currentAppearance.systemImage)
        }
        .accessibilityIdentifier("ios.appearance.menu")
    }

    private var currentAppearance: IOSAppearance {
        IOSAppearance(storedRawValue: appearanceRawValue)
    }

    private var appearanceBinding: Binding<IOSAppearance> {
        Binding(
            get: { currentAppearance },
            set: { appearanceRawValue = $0.rawValue }
        )
    }
}

struct IOSAppearanceSettingsView: View {
    @AppStorage(IOSAppearance.preferenceKey)
    private var appearanceRawValue = IOSAppearance.initialRawValue

    var body: some View {
        Form {
            Section {
                Picker("外観", selection: appearanceBinding) {
                    ForEach(IOSAppearance.allCases) { appearance in
                        Label(appearance.title, systemImage: appearance.systemImage)
                            .tag(appearance)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .accessibilityLabel("アプリの外観")
                .accessibilityIdentifier("ios.appearance.picker")
            } header: {
                Text("アプリの外観")
            } footer: {
                Text("本文キャンバスの色や作品ファイルには影響しません。")
            }
        }
        .navigationTitle("表示設定")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var currentAppearance: IOSAppearance {
        IOSAppearance(storedRawValue: appearanceRawValue)
    }

    private var appearanceBinding: Binding<IOSAppearance> {
        Binding(
            get: { currentAppearance },
            set: { appearanceRawValue = $0.rawValue }
        )
    }
}
