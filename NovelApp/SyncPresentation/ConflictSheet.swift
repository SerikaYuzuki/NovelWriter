import NovelSyncV2
import NovelSyncV2Application
import NovelUI
import SwiftUI

/// Both platforms use this sheet; platform gates remain in the supplied action.
struct ConflictSheet: View {
    let application: SyncV2Application
    let workID: WorkID
    let conflict: SyncV2ConflictProjection
    let choose: @MainActor (SyncV2ConflictChoice) async -> Bool
    let cancel: () -> Void
    @AppStorage private var deviceOverride: String
    @State private var remoteDeviceLabel: String?
    @State private var loadedConflict: SyncV2ConflictProjection?
    @State private var deviceDifference: SnapshotDifference?
    @State private var serverDifference: SnapshotDifference?
    @State private var deviceDate: Date?
    @State private var serverDate: Date?
    @State private var failed = false
    @State private var choiceGate = SnapshotConflictChoiceGate()
    @State private var confirmation: SyncV2ConflictChoice?
    #if FUMINIWA_TEST_COMPOSITION
    @State private var capturesReductionConfirmation = false
    #endif
    @State private var preview: SyncV2ConflictChoice?

    init(application: SyncV2Application, workID: WorkID, conflict: SyncV2ConflictProjection, defaults: UserDefaults,
         choose: @escaping @MainActor (SyncV2ConflictChoice) async -> Bool, cancel: @escaping () -> Void) {
        self.application = application
        self.workID = workID
        self.conflict = conflict
        self.choose = choose
        self.cancel = cancel
        _deviceOverride = AppStorage(wrappedValue: "", DeviceLabel.defaultsKey, store: defaults)
    }

    private var deviceLabel: String {
        DeviceLabel.current(deviceOverride, defaultLabel: DeviceLabelSettings.defaultLabel)
    }

    private var serverLabel: String {
        DeviceLabel.validated(remoteDeviceLabel ?? conflict.remoteDeviceLabel) ?? DeviceLabel.unknown
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.group) {
                Label("使う版を選ぶ", systemImage: "exclamationmark.triangle")
                    .font(.title2.weight(.semibold))
                version(.useDevice, title: "この端末の版", device: deviceLabel, date: deviceDate, difference: difference(.useDevice))
                version(.useServer, title: "サーバーの版", device: serverLabel, date: serverDate, difference: difference(.useServer))
                Text("選ばなかった版は履歴に残り、あとから復元できます。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("後で確認", action: cancel).buttonStyle(.borderless)
            }
            .padding(Spacing.large)
        }
        #if os(macOS)
        .frame(width: 460, height: 560)
        #endif
        .background(FuminiwaColor.paper.color)
        .disabled(choiceGate.isInFlight)
        .interactiveDismissDisabled(choiceGate.isInFlight)
        .accessibilityIdentifier("snapshotSyncV2.conflictSheet")
        .task(id: conflict) { await load() }
        .alert("本文が大きく減ります", isPresented: Binding(
            get: { confirmation != nil }, set: {
                if !$0 {
                    confirmation = nil
                }
            }
        ), presenting: confirmation) { choice in
            Button("この版を使う") { submit(choice) }
            Button("キャンセル", role: .cancel) { confirmation = nil }
        } message: { choice in
            if let reduced = difference(choice)?.reduction {
                Text("第\(reduced.number)話が\(reduced.afterCount)字になります。この版を使いますか？")
            }
        }
        .sheet(item: $preview) { choice in
            if let value = difference(choice) {
                SnapshotDifferencePreview(application: application, workID: workID,
                                          snapshotID: snapshot(choice), difference: value)
            }
        }
    }

    private func version(_ choice: SyncV2ConflictChoice, title: String, device: String, date: Date?,
                         difference: SnapshotDifference?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(title).font(.headline)
            HStack {
                Text(date.map { HistoryPresentation().versionDate($0) } ?? "保存日時不明")
                    .monospacedDigit()
                Text(device)
            }.font(.caption).foregroundStyle(.secondary)
            Text(difference?.line ?? (failed ? "内容を確認できません" : "確認中…"))
                .font(FuminiwaType.rowSecondary).foregroundStyle(.secondary).lineLimit(1)
            HStack {
                Button("中身を見る") { preview = choice }
                    .disabled(difference?.available != true)
                Spacer(minLength: Spacing.small)
                Button("この版を使う") {
                    if difference?.reduction != nil {
                        confirmation = choice
                    } else {
                        submit(choice)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(difference?.available != true)
            }
            .buttonStyle(.bordered)
            #if os(iOS)
                .frame(minHeight: 44)
            #endif
        }
        .padding(Spacing.medium)
        .background(FuminiwaColor.surface.color, in: RoundedRectangle(cornerRadius: Radius.card))
    }

    private func difference(_ choice: SyncV2ConflictChoice?) -> SnapshotDifference? {
        guard loadedConflict == conflict else { return nil }
        return choice == .useDevice ? deviceDifference : serverDifference
    }

    private func snapshot(_ choice: SyncV2ConflictChoice) -> SnapshotID {
        choice == .useDevice ? conflict.localSnapshotID : conflict.remoteSnapshotID
    }

    private func submit(_ choice: SyncV2ConflictChoice) {
        guard difference(choice)?.available == true, choiceGate.begin() else { return }
        confirmation = nil
        Task {
            if await !choose(choice) {
                choiceGate.retryAfterFailure()
            }
        }
    }

    private func load() async {
        loadedConflict = nil
        deviceDate = nil
        serverDate = nil
        confirmation = nil
        preview = nil
        failed = false
        remoteDeviceLabel = nil
        do {
            let device = try await application.snapshotDifference(workID: workID, before: conflict.remoteSnapshotID, after: conflict.localSnapshotID)
            let server = try await application.snapshotDifference(workID: workID, before: conflict.localSnapshotID, after: conflict.remoteSnapshotID)
            guard !Task.isCancelled else { return }
            loadedConflict = conflict
            deviceDifference = device
            serverDifference = server
            #if FUMINIWA_TEST_COMPOSITION
            if capturesReductionConfirmation {
                confirmation = .useServer
            }
            #endif
            let localDate = try await application.localSnapshotDate(workID: workID, snapshotID: conflict.localSnapshotID)
            let remoteDate = try? await application.remoteSnapshotDate(workID: workID, snapshotID: conflict.remoteSnapshotID)
            guard !Task.isCancelled else { return }
            deviceDate = localDate
            serverDate = remoteDate
            // Device labels are an opt-in remote read; the sheet stays usable
            // with the local projection when the server is unreachable.
            if let remote = try? await application.remoteConflict(workID: workID), !Task.isCancelled,
               remote.conflictID == conflict.conflictID, remote.revision == conflict.revision,
               remote.localSnapshotID == conflict.localSnapshotID, remote.remoteSnapshotID == conflict.remoteSnapshotID {
                remoteDeviceLabel = remote.remoteDeviceLabel
            }
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
        }
    }
}

extension SyncV2ConflictChoice: @retroactive Identifiable {
    public var id: String {
        rawValue
    }
}

#if FUMINIWA_TEST_COMPOSITION
extension ConflictSheet {
    func presentingReductionForCapture() -> Self {
        var sheet = self
        sheet._capturesReductionConfirmation = State(initialValue: true)
        return sheet
    }
}
#endif
