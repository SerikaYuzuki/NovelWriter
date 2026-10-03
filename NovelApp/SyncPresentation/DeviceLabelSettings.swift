import NovelSyncV2
import NovelSyncV2Application
import SwiftUI

enum DeviceLabelSettings {
    @MainActor static var defaultLabel: String {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #else
        "Mac"
        #endif
    }

    @MainActor static func provider(defaults: UserDefaults) -> DeviceLabelProvider {
        { @MainActor in
            DeviceLabel.current(defaults.string(forKey: DeviceLabel.defaultsKey), defaultLabel: defaultLabel)
        }
    }
}

struct DeviceLabelSettingsView: View {
    @AppStorage private var override: String

    init(defaults: UserDefaults) {
        _override = AppStorage(wrappedValue: "", DeviceLabel.defaultsKey, store: defaults)
    }

    var body: some View {
        TextField("保存した端末名", text: Binding(
            get: { override }, set: { override = DeviceLabel.setting($0) }
        ), prompt: Text(DeviceLabelSettings.defaultLabel))
            .help("40文字まで。空欄では端末の種類を使います。この端末だけの設定です。")
    }
}

struct ConflictDeviceLabels: View {
    let conflict: SyncV2ConflictProjection
    let application: SyncV2Application?
    let workID: WorkID
    @AppStorage private var override: String
    @State private var fetched: SyncV2ConflictProjection?

    init(conflict: SyncV2ConflictProjection, application: SyncV2Application?, workID: WorkID, defaults: UserDefaults) {
        self.conflict = conflict
        self.application = application
        self.workID = workID
        _override = AppStorage(wrappedValue: "", DeviceLabel.defaultsKey, store: defaults)
    }

    var body: some View {
        VStack(alignment: .leading) {
            Text("この端末の版：\(DeviceLabel.current(override, defaultLabel: DeviceLabelSettings.defaultLabel))")
            Text("サーバーの版：\(DeviceLabel.validated(currentConflict.remoteDeviceLabel) ?? DeviceLabel.unknown)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .task(id: conflict) {
            fetched = nil
            guard let value = try? await application?.remoteConflict(workID: workID),
                  !Task.isCancelled, matches(value) else { return }
            fetched = value
        }
    }

    private var currentConflict: SyncV2ConflictProjection {
        if let fetched, matches(fetched) {
            return fetched
        }
        return conflict
    }

    private func matches(_ value: SyncV2ConflictProjection) -> Bool {
        value.conflictID == conflict.conflictID && value.revision == conflict.revision &&
            value.localSnapshotID == conflict.localSnapshotID && value.remoteSnapshotID == conflict.remoteSnapshotID &&
            value.sourceGeneration == conflict.sourceGeneration
    }
}
