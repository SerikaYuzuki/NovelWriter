import NovelWorkspaceUI
import NovelWritingSupport
import SwiftUI

@MainActor
enum WritingPrompts {
    static func migrateIfNeeded(host: WritingAssistantHost, defaults: UserDefaults) async throws {
        let existing = try await host.records(true)
        for purpose in AssistantPurpose.allCases where !existing.contains(where: { $0.record.kind == "prompt" && $0.record.key == purpose.id }) {
            let text = AssistantPreferences(defaults: defaults).prompt(purpose)
            try await host.append(WritingRecord(workId: nil, kind: "prompt", key: purpose.id,
                                                payload: WritingRecord.payload(WritingPrompt(text: text))))
        }
    }

    static func latest(_ records: [WritingEnvelope], purpose: AssistantPurpose) -> WritingEnvelope? {
        let candidates = records.filter { $0.record.kind == "prompt" && $0.record.key == purpose.id && !$0.conflicted }
        return candidates.last(where: { $0.sequence == 0 }) ?? candidates.max(by: { $0.sequence < $1.sequence })
    }

    static func effective(host: WritingAssistantHost, defaults: UserDefaults, purpose: AssistantPurpose) async throws -> String {
        let common = try await host.records(true), work = try await host.records(false)
        let base = try latest(common, purpose: purpose)?.record.decoded(WritingPrompt.self).text ?? AssistantPreferences(defaults: defaults)
            .prompt(purpose)
        let addition = try latest(work, purpose: purpose)?.record.decoded(WritingPrompt.self).text ?? ""
        return base + (addition.isEmpty ? "" : "\n作品別の指定（共通設定より優先）:\n" + addition)
    }
}

struct WritingPromptsView: View {
    let host: WritingAssistantHost
    let defaults: UserDefaults
    @State private var purpose = AssistantPurpose.advice
    @State private var common = true
    @State private var text = ""
    @State private var base: UUID?
    @State private var records: [WritingEnvelope] = []
    @State private var notice: String?
    @State private var saving = false

    var body: some View {
        Form {
            Section {
                Picker("用途", selection: $purpose) { ForEach(AssistantPurpose.allCases) { Text($0.rawValue).tag($0) } }
                Picker("適用先", selection: $common) {
                    Text("全作品の共通設定").tag(true); Text("この作品への追加指定").tag(false)
                }
                Text("共通設定に作品別の指定を加え、次の依頼から使用します。競合した案も残ります。")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $text).frame(minHeight: 200, idealHeight: 300)
                    .accessibilityLabel("AIに渡すプロンプト")
                Button("この内容を保存") { Task { await save() } }.disabled(saving)
                if let notice {
                    Text(notice).font(.caption)
                }
            }
            let conflicts = records.filter { $0.conflicted && $0.record.kind == "prompt" && $0.record.key == purpose.id }
            if !conflicts.isEmpty {
                Section("同時に変更された案") {
                    ForEach(conflicts) { item in
                        if let prompt = try? item.record.decoded(WritingPrompt.self) {
                            DisclosureGroup("\(item.record.createdAt.prefix(10)) の案") {
                                Text(prompt.text).textSelection(.enabled)
                                Button("編集欄に取り込む") { text = prompt.text; notice = "内容を確認し、保存すると現在の設定に採用します。" }
                            }
                        }
                    }
                }
            }
        }.formStyle(.grouped).navigationTitle("同期するプロンプト")
            .modifier(WritingSyncVisibility(host: host))
            .task(id: "\(host.contextID)-\(purpose.id)-\(common)") { await load() }
    }

    private func load() async {
        do {
            try? await host.synchronizeNow()
            try await WritingPrompts.migrateIfNeeded(host: host, defaults: defaults)
            records = try await host.records(common)
            let latest = WritingPrompts.latest(records, purpose: purpose)
            base = latest?.id
            text = try latest?.record.decoded(WritingPrompt.self).text ?? (common ? AssistantPreferences(defaults: defaults).prompt(purpose) : "")
        } catch { notice = error.localizedDescription }
    }

    private func save() async {
        saving = true; defer { saving = false }
        do {
            guard text.utf8.count <= 100_000 else { throw AssistantError.tooLarge }
            let capture = try host.capture()
            let record = try WritingRecord(workId: common ? nil : capture.workId, kind: "prompt", key: purpose.id,
                                           parentId: base, payload: WritingRecord.payload(WritingPrompt(text: text)))
            try await host.append(record); base = record.id
            notice = "この端末に保存しました。接続できると同期します。"
            do { try await host.synchronizeNow() } catch { return }
            records = try await host.records(common)
            if records.first(where: { $0.id == record.id })?.conflicted == true {
                notice = "別端末の変更と重なりました。両方の案を残しました。内容を確認して保存し直してください。"
                base = WritingPrompts.latest(records, purpose: purpose)?.id
            }
        } catch { notice = error.localizedDescription }
    }
}
