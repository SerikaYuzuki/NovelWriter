import NovelWorkspaceUI
import NovelWritingSupport
import SwiftUI

struct WritingEditHistoryView: View {
    let host: WritingAssistantHost
    @State private var records: [WritingEnvelope] = []
    @State private var entries: [WritingEnvelope] = []
    @State private var states: [UUID: String] = [:]
    @State private var notice: String?
    private let names = ["title": "タイトル", "synopsis": "あらすじ", "chapters": "章", "episodes": "話", "content": "本文",
                         "characters": "登場人物", "plotCards": "プロット", "flags": "伏線", "worldNotes": "設定ノート", "memo": "メモ", "attachments": "添付資料", "thumbnails": "サムネイル", "work": "表紙"]
    var body: some View {
        List {
            if records.isEmpty {
                Text("AIによる変更の記録はありません。")
            }
            if let notice {
                Text(notice).font(.caption)
            }
            ForEach(records) { item in
                if let edit = try? host.decodedEdit(item.record, entries: entries) {
                    DisclosureGroup {
                        ForEach(Array(edit.changes.enumerated()), id: \.offset) { _, change in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(change.path.compactMap { names[$0] }.joined(separator: " / ")).font(.headline)
                                if change.path.first == "thumbnails" {
                                    Text("サムネイルの設定・差し替え・削除").font(.caption)
                                } else if change.path.first == "attachments" {
                                    Text("添付資料の追加・更新・削除または並べ替え").font(.caption)
                                } else {
                                    Text("変更前").font(.caption).foregroundStyle(.secondary)
                                    Text(readable(change.before)).textSelection(.enabled)
                                    Text("変更後").font(.caption).foregroundStyle(.secondary)
                                    Text(readable(change.after)).textSelection(.enabled)
                                }
                            }
                        }
                        if ["applied", "prepared"].contains(states[edit.id] ?? "") {
                            Button("この依頼の変更を取り消す") {
                                Task {
                                    do { try await host.undo(edit.id); notice = "変更を取り消しました。"; await load() }
                                    catch { notice = error.localizedDescription }
                                }
                            }
                        }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(edit.changes.compactMap { $0.path.first.flatMap { names[$0] } }.uniquedForWritingHistory.joined(separator: "・"))
                            Text("\(item.record.createdAt.prefix(16).replacingOccurrences(of: "T", with: " ")) ・ \(stateLabel(states[edit.id]))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }.navigationTitle("AIの変更履歴")
            .modifier(WritingSyncVisibility(host: host))
            .task(id: host.contextID) { await load() }
    }

    private func load() async {
        do {
            entries = try await host.records(false)
            for id in host.proofreadingEditIDs(defaults: host.defaults) {
                if let edit = try await host.localEdit(id), !entries.contains(where: { $0.record.kind == "edit" && $0.record.key == id.uuidString.lowercased() }) {
                    // The full edit comes from the local Undo journal, never from synced records.
                    try entries.append(WritingEnvelope(record: WritingRecord(id: id, workId: host.workID, kind: "edit",
                                                                             key: id.uuidString.lowercased(), payload: WritingRecord.payload(edit))))
                }
            }
            records = Array(entries.filter { $0.record.kind == "edit" }.suffix(100).reversed())
            for item in records {
                if let edit = try? host.decodedEdit(item.record, entries: entries), let state = try await host.editState(edit.id) {
                    states[edit.id] = state
                }
            }
        } catch { notice = error.localizedDescription }
    }

    private func stateLabel(_ state: String?) -> String {
        switch state {
        case "applied": "反映済み"
        case "undone": "取り消し済み"
        case "rejected": "反映しませんでした"
        case "prepared": "完了を確認できない記録"
        default: "参照用の記録"
        }
    }

    private func readable(_ value: WritingValue?) -> String {
        guard let value else { return "（なし）" }
        switch value {
        case let .string(text): return String(text.prefix(12000))
        case let .object(items): return items.filter { $0.key != "id" }.sorted { $0.key < $1.key }
            .map { "\(names[$0.key] ?? $0.key)：\(readable($0.value))" }.joined(separator: "\n")
        case let .array(items): return items.map { readable($0) }.joined(separator: "\n\n")
        case .null: return "（なし）"
        case let .bool(value): return value ? "済" : "未"
        case let .number(value): return String(value)
        }
    }
}

private extension [String] {
    var uniquedForWritingHistory: [String] {
        var seen = Set<String>(); return filter { seen.insert($0).inserted }
    }
}
