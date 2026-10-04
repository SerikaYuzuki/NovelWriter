import SwiftUI

/// Remains outside the frozen editor's disabled subtree.
public struct KeepBothRecoveryView: View {
    public init(retry: @escaping @MainActor () async -> Bool, leave: @escaping @MainActor () async -> Bool) {
        self.retry = retry
        self.leave = leave
    }

    private let retry: @MainActor () async -> Bool
    private let leave: @MainActor () async -> Bool
    @State private var busy = false

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("複製を開けませんでした。元の作品への書込みを保留しています。", systemImage: "exclamationmark.triangle")
            HStack {
                Button("もう一度開く") { perform(retry) }
                Button("作品一覧に戻る") { perform(leave) }
                if busy {
                    ProgressView().controlSize(.small)
                }
            }
            .disabled(busy)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }

    private func perform(_ operation: @escaping @MainActor () async -> Bool) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            _ = await operation()
            busy = false
        }
    }
}
