import NovelUI
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
        if !existing.contains(where: { $0.record.kind == "prompt" && $0.record.key == ProofreadingChecklist.key }) {
            try await host.append(WritingRecord(workId: nil, kind: "prompt", key: ProofreadingChecklist.key,
                                                payload: WritingRecord.payload(ProofreadingChecklist.defaults)))
        }
    }

    static func checklist(host: WritingAssistantHost) async throws -> ProofreadingChecklist {
        let common = try await host.records(true), work = try await host.records(false)
        return try ProofreadingChecklist.effective(common: common, work: work)
    }

    static func saveChecklist(host: WritingAssistantHost, selection: Set<String>, common: Bool, parent: UUID?) async throws -> WritingRecord {
        let capture = try host.capture()
        let record = try WritingRecord(workId: common ? nil : capture.workId, kind: "prompt", key: ProofreadingChecklist.key,
                                       parentId: parent, payload: WritingRecord.payload(ProofreadingChecklist(selection: selection)))
        try await host.append(record)
        return record
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
    @State private var checks = Set(ProofreadingChecklist.defaults.checks)
    @State private var checklistBase: UUID?
    @State private var resetTarget: ResetTarget?

    private enum ResetTarget: String, Identifiable {
        case prompt, checklist
        var id: String {
            rawValue
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("用途", selection: $purpose) { ForEach(AssistantPurpose.allCases) { Text($0.label).tag($0) } }.disabled(saving)
                Picker("適用先", selection: $common) {
                    Text("全作品の共通設定").tag(true); Text("この作品への追加指定").tag(false)
                }.disabled(saving)
                Text("共通設定に作品別の指定を加え、次の依頼から使用します。競合した案も残ります。")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $text).japaneseTextEditorStyle().frame(minHeight: 200, idealHeight: 300)
                    .accessibilityLabel("AIに渡すプロンプト")
                Button("この内容を保存") { Task { await save() } }.disabled(saving)
                Button("初期値を読み込む") { resetTarget = .prompt }.disabled(saving)
                if let notice {
                    Text(notice).font(.caption)
                }
            }
            if purpose == .proofreading {
                Section("校正のチェック項目") {
                    Text(common ? "全作品の初期設定です。作品別の設定がある場合は、そちらを優先します。" : "この作品では共通設定の代わりに、この選択を使います。")
                        .font(.caption).foregroundStyle(.secondary)
                    ProofreadingChecklistView(selection: $checks).disabled(saving)
                    Button("チェック項目を保存") { Task { await saveChecks() } }.disabled(saving)
                    Button("初期値を読み込む") { resetTarget = .checklist }.disabled(saving)
                    let conflicts = records.filter { $0.conflicted && $0.record.kind == "prompt" && $0.record.key == ProofreadingChecklist.key }
                    ForEach(conflicts) { item in
                        if let candidate = try? item.record.decoded(ProofreadingChecklist.self) {
                            DisclosureGroup("\(item.record.createdAt.prefix(10)) のチェック項目の案") {
                                Text(ProofreadingCheck.allCases.filter { candidate.checks.contains($0.id) }.map(\.label).joined(separator: "\n"))
                                Button("選択に取り込む") {
                                    checks = Set(candidate.checks)
                                    notice = "内容を確認し、保存すると現在の設定に採用します。"
                                }
                            }
                        }
                    }
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
            .sheet(item: $resetTarget) { target in
                VStack(alignment: .leading, spacing: 16) {
                    Text("\(target == .prompt ? purpose.label + "の指示" : "校正のチェック項目")を初期値に戻しますか？").font(.headline)
                    Text("\(common ? "全作品の共通設定" : "この作品の設定")を、現在のアプリの初期値で保存し直します。")
                    ScrollView {
                        Text(target == .prompt ? purpose.defaultPrompt : ProofreadingChecklist.defaults.instructions)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack {
                        Button("キャンセル") { resetTarget = nil }
                        Spacer()
                        Button("初期値を読み込んで保存") {
                            resetTarget = nil
                            Task {
                                if target == .prompt {
                                    text = purpose.defaultPrompt; await save()
                                } else {
                                    checks = Set(ProofreadingChecklist.defaults.checks); await saveChecks()
                                }
                            }
                        }.buttonStyle(.borderedProminent)
                    }
                }.padding(20).frame(minWidth: 300, idealWidth: 500, minHeight: 360)
                    .interactiveDismissDisabled(saving)
            }
    }

    private func load() async {
        do {
            try? await host.synchronizeNow()
            try await WritingPrompts.migrateIfNeeded(host: host, defaults: defaults)
            let loaded = try await host.records(common)
            try Task.checkCancellation()
            records = loaded
            let checklist = ProofreadingChecklist.latest(records)
            checklistBase = checklist?.id
            let fallback = common ? ProofreadingChecklist.defaults : try await WritingPrompts.checklist(host: host)
            try Task.checkCancellation()
            checks = try Set(checklist?.record.decoded(ProofreadingChecklist.self).checks ?? fallback.checks)
            let latest = WritingPrompts.latest(records, purpose: purpose)
            base = latest?.id
            text = try latest?.record.decoded(WritingPrompt.self).text ?? (common ? AssistantPreferences(defaults: defaults).prompt(purpose) : "")
        } catch { notice = error.localizedDescription }
    }

    private func saveChecks() async {
        saving = true; defer { saving = false }
        do {
            let record = try await WritingPrompts.saveChecklist(host: host, selection: checks, common: common, parent: checklistBase)
            checklistBase = record.id
            notice = "この端末に保存しました。接続できると同期します。"
            try? await host.synchronizeNow()
            records = try await host.records(common)
            if records.first(where: { $0.id == record.id })?.conflicted == true {
                notice = "別端末の変更と重なりました。両方の案を残しました。選択を確認して保存し直してください。"
                checklistBase = ProofreadingChecklist.latest(records)?.id
            }
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
