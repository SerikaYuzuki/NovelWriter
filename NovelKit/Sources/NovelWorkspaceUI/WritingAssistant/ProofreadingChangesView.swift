import SwiftUI

public struct ProofreadingChangesView: View {
    private let result: ProofreadingChanges.Application
    public init(result: ProofreadingChanges.Application) {
        self.result = result
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if result.accepted.isEmpty, result.rejected.isEmpty {
                Text("修正はありませんでした。")
            }
            if !result.accepted.isEmpty {
                Text("変更案（\(result.accepted.count)件）").font(.headline)
                ForEach(Array(result.accepted.enumerated()), id: \.offset) { _, change in
                    changeView(change)
                }
            }
            if !result.rejected.isEmpty {
                Text("適用できなかった提案").font(.headline)
                ForEach(Array(result.rejected.enumerated()), id: \.offset) { _, rejected in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(rejected.explanation).foregroundStyle(.secondary)
                        changeView(rejected.change)
                    }
                }
            }
        }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func changeView(_ change: ProofreadingChange) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ProofreadingCheck(rawValue: change.check)?.label ?? "その他").font(.caption).foregroundStyle(.secondary)
            Text("修正前").font(.caption)
            Text(verbatim: change.before)
            Text("修正後").font(.caption)
            Text(verbatim: change.after.isEmpty ? "（削除）" : change.after)
            Text(verbatim: "理由: " + change.reason).foregroundStyle(.secondary)
            Divider()
        }
    }
}
