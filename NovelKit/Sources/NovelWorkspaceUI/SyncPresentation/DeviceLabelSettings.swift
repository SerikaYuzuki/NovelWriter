import NovelSyncV2
import NovelSyncV2Application
import SwiftUI

public enum DeviceLabelSettings {
    @MainActor public static var defaultLabel: String {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #else
        "Mac"
        #endif
    }

    @MainActor public static func provider(defaults: UserDefaults) -> DeviceLabelProvider {
        { @MainActor in
            DeviceLabel.current(defaults.string(forKey: DeviceLabel.defaultsKey), defaultLabel: defaultLabel)
        }
    }
}

public struct DeviceLabelSettingsView: View {
    @AppStorage private var override: String

    public init(defaults: UserDefaults) {
        _override = AppStorage(wrappedValue: "", DeviceLabel.defaultsKey, store: defaults)
    }

    public var body: some View {
        TextField("保存した端末名", text: Binding(
            get: { override }, set: { override = DeviceLabel.setting($0) }
        ), prompt: Text(DeviceLabelSettings.defaultLabel))
            .help("40文字まで。空欄では端末の種類を使います。この端末だけの設定です。")
    }
}
