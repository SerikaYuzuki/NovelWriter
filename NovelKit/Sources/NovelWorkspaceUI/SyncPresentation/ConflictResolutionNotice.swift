import NovelSyncV2
import NovelSyncV2Application
import NovelUI
import SwiftUI

public struct ConflictResolutionNotice: Identifiable {
    public init(title: String, undo: (@MainActor () async -> Bool)?, history: @escaping @MainActor () -> Void) {
        self.title = title
        self.undo = undo
        self.history = history
    }

    public let id = UUID()
    let title: String
    let undo: (@MainActor () async -> Bool)?
    let history: @MainActor () -> Void
}

public struct ConflictResolutionNoticeView: View {
    public init(notice: ConflictResolutionNotice, dismiss: @escaping () -> Void) {
        self.notice = notice
        self.dismiss = dismiss
    }

    let notice: ConflictResolutionNotice
    let dismiss: () -> Void
    @State private var undoTask: Task<Void, Never>?
    @State private var busy = false
    @State private var failed = false

    public var body: some View {
        HStack(spacing: Spacing.small) {
            Text(failed ? "反映待ち、または復元できませんでした。履歴を確認してください。" : busy ? "版の反映を待っています…" : notice.title)
                .font(FuminiwaType.rowSecondary)
            Spacer(minLength: 0)
            if let undo = notice.undo, !failed {
                Button("元に戻す") {
                    guard !busy else { return }
                    busy = true
                    undoTask = Task {
                        if await undo() {
                            dismiss()
                        } else {
                            busy = false; failed = true
                        }
                    }
                }.disabled(busy)
            } else {
                Button("履歴を開く") { notice.history(); dismiss() }
            }
            Button("閉じる", systemImage: "xmark", action: dismiss).labelStyle(.iconOnly)
        }
        .padding(Spacing.medium).background(FuminiwaColor.surface.color)
        .onDisappear { undoTask?.cancel() }
        .task(id: notice.id) {
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            if !busy {
                dismiss()
            }
        }
    }
}
