import NovelSync
import SwiftUI

extension EnvironmentValues {
    @Entry var iosNoteSyncConflictPresented: Binding<Bool> = .constant(false)
}

struct IOSNoteSyncConflictResolutionView: View {
    let workTitle: String
    let isApplying: Bool
    let choose: (NoteSyncConflictChoice) -> Void
    let reviewLater: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("「\(displayTitle)」は、この端末とiCloudの両方で変わっています。内容を一つにまとめず、残す側を選べます。")
                    .foregroundStyle(.secondary)
                Text("閉じても編集は続けられます。選ぶまでは両方の内容を残します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("この端末の内容を使う") { choose(.keepLocal) }
                    .accessibilityIdentifier("noteSync.keepLocal")
                Button("iCloudの内容を使う") { choose(.keepRemote) }
                    .accessibilityIdentifier("noteSync.keepRemote")
                Button("両方を別作品として残す") { choose(.keepBoth) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("noteSync.keepBoth")
                if isApplying {
                    ProgressView()
                        .accessibilityLabel("選択した内容を保存しています")
                }
                Spacer()
            }
            .padding()
            .disabled(isApplying)
            .navigationTitle("変更の確認が必要です")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("あとで", action: reviewLater)
                }
            }
        }
        .accessibilityIdentifier("noteSync.review")
    }

    private var displayTitle: String {
        workTitle.isEmpty ? "名称未設定の作品" : workTitle
    }
}

struct IOSNoteSyncConflictSheetModifier: ViewModifier {
    @Bindable var store: IOSDocumentStore
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                if let conflict = store.noteSyncConflict {
                    IOSNoteSyncConflictResolutionView(
                        workTitle: store.document.title,
                        isApplying: store.workSyncIsApplyingConflict,
                        choose: { choice in
                            Task {
                                await store.resolveNoteSyncConflict(
                                    using: choice,
                                    expectedConflict: conflict
                                )
                            }
                        },
                        reviewLater: { isPresented = false }
                    )
                    .id("\(conflict.workID.rawValue.uuidString)-\(conflict.keys.count)")
                    .presentationDetents([.medium, .large])
                }
            }
            .onChange(of: store.noteSyncConflict, initial: true) { _, conflict in
                if conflict != nil {
                    isPresented = true
                } else {
                    isPresented = false
                }
            }
    }
}

extension View {
    func iosNoteSyncConflictSheet(
        store: IOSDocumentStore,
        isPresented: Binding<Bool>
    ) -> some View {
        modifier(IOSNoteSyncConflictSheetModifier(store: store, isPresented: isPresented))
    }
}
