import NovelCore
import NovelUI
import NovelWorkspace
import NovelWorkspaceUI
import NovelWritingSupport
import SwiftUI

/// The app owns requests; this view prepares previews and displays durable results.
struct AssistantPanelView: View {
    let defaults: UserDefaults
    let contextID: String
    let episodeTitle: String
    let currentEpisodeID: EpisodeID?
    let capture: () throws -> AssistantManuscript
    let close: () -> Void
    var applyProofreading: ((AssistantManuscript, String) -> Bool)?
    var saveFeedback: ((AssistantFeedback) async -> Bool)?
    var writingHost: WritingAssistantHost?
    var chapters: [Chapter] = []
    var document: NovelDocument?
    var captureScope: ((AssistantScope) throws -> AssistantManuscript)?
    @State private var checks = Set(ProofreadingChecklist.defaults.checks)
    @State private var savedChecks = Set(ProofreadingChecklist.defaults.checks)
    @State private var checklistBase: UUID?
    @State private var checklistLoaded = false
    @State private var isSavingChecklist = false
    @State private var feedbackContext = Set(AssistantFeedbackContext.allCases)
    @State private var proofreadingResult: ProofreadingChanges.Application?
    @State private var showingPrompts = false
    @State private var scope = AssistantScope.current
    @State private var pendingPurpose = AssistantPurpose.proofreading
    @State private var purpose = AssistantPurpose.proofreading
    @State private var answer = ""
    @State private var notice: String?
    @State private var pending: AssistantManuscript?
    @State private var pendingConfiguration: AssistantConfiguration?
    #if os(iOS)
    @State private var showingSettings = false
    #endif
    @State private var requestEntries: [WritingEnvelope] = []
    @State private var confirmingProofreading = false
    @State private var requestTask: Task<Void, Never>?
    @State private var requestID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("AI支援", systemImage: "sparkles").font(.headline)
                    .foregroundStyle(FuminiwaColor.accent.color)
                    .symbolRenderingMode(.hierarchical)
                Spacer()
                #if os(macOS)
                SettingsLink { Label("設定", systemImage: "gearshape") }
                    .labelStyle(.iconOnly)
                    .help("設定の「AI支援」を開く")
                #else
                Button("設定", systemImage: "gearshape") { showingSettings = true }
                    .labelStyle(.iconOnly)
                #endif
                Button("閉じる", systemImage: "xmark", action: close).labelStyle(.iconOnly)
            }
            Picker("用途", selection: $purpose) {
                ForEach(AssistantPurpose.allCases.filter { $0 != .advice || writingHost != nil }) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented)
            if purpose == .advice, let writingHost {
                AssistantChatView(host: writingHost, defaults: defaults, chapters: chapters,
                                  currentEpisodeID: currentEpisodeID, referenceScope: $scope)
            } else {
                if purpose == .proofreading {
                    Text("校正する範囲：現在の1話（\(episodeTitle)）")
                        .font(.subheadline)
                    DisclosureGroup("チェック項目") {
                        ScrollView {
                            ProofreadingChecklistView(selection: $checks)
                            if writingHost != nil {
                                Button(isSavingChecklist ? "保存中…" : "この作品のチェック項目を保存") {
                                    Task { await savePanelChecklist() }
                                }.disabled(!checklistLoaded || isSavingChecklist || checks == savedChecks)
                                Text("選択を変えて送信すると、この作品の設定として保存します。共通の初期設定は「指示」で編集できます。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.frame(maxHeight: 240)
                    }.disabled((requestTask != nil || inFlight) || isSavingChecklist || (writingHost != nil && !checklistLoaded))
                } else {
                    AssistantScopeSelector(chapters: chapters, currentID: currentEpisodeID, scope: $scope)
                    DisclosureGroup("一緒に送る参考情報") {
                        ForEach(AssistantFeedbackContext.allCases) { item in
                            Toggle(item.label, isOn: Binding(get: { feedbackContext.contains(item) }, set: { enabled in
                                if enabled {
                                    feedbackContext.insert(item)
                                } else {
                                    feedbackContext.remove(item)
                                }
                            }))
                        }
                    }
                }
                HStack {
                    Button("本文を確認して送信…", action: prepare)
                        .disabled((requestTask != nil || inFlight) || isSavingChecklist || (purpose == .proofreading && writingHost != nil && !checklistLoaded) || effectiveScope.selectedEpisodeIDs(
                            chapters: chapters, currentID: currentEpisodeID
                        ).isEmpty)
                    if writingHost != nil {
                        Button("指示") { showingPrompts = true }.disabled((requestTask != nil || inFlight) || isSavingChecklist)
                    }
                    if requestTask != nil {
                        ProgressView().controlSize(.small)
                    }
                }
                if let writingHost {
                    AssistantRequestStatusView(host: writingHost, key: writingHost.requestKey(purpose: purpose), defaults: defaults, rebuild: { prepare() })
                    if let latestRequest, let metadata = try? latestRequest.record.decoded(AssistantRequestRecord.self) {
                        if metadata.state == "pending", purpose == .proofreading, metadata.episodeId == currentEpisodeID {
                            Label("未反映の校正結果があります", systemImage: "doc.badge.clock").font(.caption)
                            Button("結果を確認して反映…") { confirmingProofreading = true }
                        } else if !inFlight, ["interrupted", "failed", "cancelled"].contains(metadata.state)
                            || (metadata.state == "sent" && writingHost.interrupted(latestRequest.record, defaults: defaults)) {
                            Label("中断した依頼があります", systemImage: "exclamationmark.triangle").font(.caption)
                            Button("再送", action: retry)
                        } else if !inFlight, let detail = metadata.detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                ScrollView {
                    Group {
                        if let proofreadingResult {
                            ProofreadingChangesView(result: proofreadingResult)
                        } else {
                            AssistantMarkdownView(source: answer.isEmpty ? "校正の変更案・感想がここに表示されます。" : answer)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(Spacing.medium)
                    .background(FuminiwaColor.surface.color, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .modifier(WritingSyncVisibility(host: writingHost))
        .padding(16)
        .frame(minWidth: 300, idealWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        .background(FuminiwaColor.paper.color)
        .task(id: contextID) { await loadChecklist(); await loadRequestResults() }
        .onChange(of: writingHost?.requestCenter.revision) { _, _ in Task { await loadRequestResults() } }
        .confirmationDialog("送信時と同じ本文なら校正を反映しますか？", isPresented: $confirmingProofreading) {
            Button("反映") { Task { await confirmProofreading() } }
            Button("キャンセル", role: .cancel) {}
        } message: { Text("本文が変わっている場合は、変更一覧だけを表示して本文を保ちます。") }
        .sheet(isPresented: $showingPrompts, onDismiss: { Task { await loadChecklist() } }) {
            if let writingHost {
                NavigationStack {
                    WritingPromptsView(host: writingHost, defaults: defaults)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { showingPrompts = false } } }
                }.frame(minWidth: 300, minHeight: 480)
            }
        }
        #if os(iOS)
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                AssistantSettingsView(defaults: defaults, writingHost: writingHost)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { showingSettings = false } } }
            }.frame(minWidth: 340, minHeight: 480)
        }
        #endif
        .sheet(isPresented: Binding(get: { pending != nil }, set: {
            if !$0 {
                pending = nil; pendingConfiguration = nil
            }
        })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("\(pendingPurpose.rawValue)に送信する本文").font(.headline)
                if pendingPurpose == .impressions {
                    Text("回答は「感想」に日時付きで保存し、作品のAI記録として同期します。")
                        .font(.caption)
                }
                if pendingPurpose == .proofreading, canApplyProofreading {
                    Text("校正が完了すると本文を上書きし、変更箇所を色で示します。取り消しできます。")
                        .font(.caption)
                }
                Text("送信先：\(pendingConfiguration?.endpoint.absoluteString ?? "")").font(.caption)
                Text("\(pending?.title ?? "") ・ \(pending?.content.count ?? 0)文字")
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("送信する指示").font(.headline)
                        Text(pendingConfiguration?.instructions ?? "")
                        if let reference = pending?.reference {
                            Text("参考情報（引用データ・修正対象外）").font(.headline)
                            Text(reference)
                        }
                        Text("本文").font(.headline)
                        Text(pending?.content ?? "")
                    }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("キャンセル") { pending = nil; pendingConfiguration = nil }
                    Spacer()
                    Button("この本文を送信", action: send).buttonStyle(.borderedProminent)
                }
            }.padding(20).frame(minWidth: 340, idealWidth: 500, minHeight: 420)
        }
        .onChange(of: contextID) { _, _ in reset(); scope = .current; checklistLoaded = false; feedbackContext = Set(AssistantFeedbackContext.allCases) }
        .onChange(of: purpose) { _, _ in reset(); Task { await loadRequestResults() } }
        .onChange(of: scope) { _, _ in reset() }
        .onChange(of: chapters.map { $0.id.description + $0.episodes.map(\.id.description).joined() }) { _, _ in reset(); scope = .current }
        .onDisappear { reset() }
    }

    private var inFlight: Bool {
        guard let writingHost else { return false }
        return writingHost.requestCenter.statuses[writingHost.requestKey(purpose: purpose)]?.inFlight == true
    }

    private var latestRequest: WritingEnvelope? {
        AssistantRequestRecord.latest(requestEntries).filter {
            guard let metadata = try? $0.record.decoded(AssistantRequestRecord.self), metadata.purpose == purpose else { return false }
            return purpose != .proofreading || metadata.episodeId == currentEpisodeID
        }.max { $0.record.createdAt < $1.record.createdAt }
    }

    private var effectiveScope: AssistantScope {
        scope.forPurpose(purpose)
    }

    private var canApplyProofreading: Bool {
        effectiveScope == .current && applyProofreading != nil
    }
}

private extension AssistantPanelView {
    func loadChecklist() async {
        guard let writingHost else { checklistLoaded = true; return }
        do {
            try? await writingHost.synchronizeNow()
            let common = try await writingHost.records(true), work = try await writingHost.records(false)
            let selected = try ProofreadingChecklist.effective(common: common, work: work)
            try Task.checkCancellation()
            checks = Set(selected.checks); savedChecks = checks
            checklistBase = ProofreadingChecklist.latest(work)?.id
            checklistLoaded = true
        } catch {
            if !Task.isCancelled {
                notice = error.localizedDescription
            }
        }
    }

    @discardableResult
    private func savePanelChecklist() async -> Bool {
        guard let writingHost, !isSavingChecklist else { return false }
        let selection = checks
        isSavingChecklist = true; defer { isSavingChecklist = false }
        do {
            let record = try await WritingPrompts.saveChecklist(host: writingHost, selection: selection, common: false, parent: checklistBase)
            try Task.checkCancellation()
            checklistBase = record.id; savedChecks = selection
            notice = "この作品のチェック項目を保存しました。接続できると同期します。"
            try? await writingHost.synchronizeNow()
            let records = try await writingHost.records(false)
            if records.first(where: { $0.id == record.id })?.conflicted == true {
                checklistBase = ProofreadingChecklist.latest(records)?.id
                let common = try await writingHost.records(true)
                savedChecks = try Set(ProofreadingChecklist.effective(common: common, work: records).checks)
                notice = "別端末のチェック項目と重なりました。「指示」で案を確認して保存し直してください。"
                return false
            }
            return true
        } catch {
            if !Task.isCancelled {
                notice = error.localizedDescription
            }; return false
        }
    }

    private func prepare() {
        guard requestTask == nil, !inFlight else { return }
        let id = UUID(); requestID = id
        let chosenPurpose = purpose
        requestTask = Task { @MainActor in
            defer {
                if requestID == id {
                    requestTask = nil
                }
            }
            do {
                if chosenPurpose == .proofreading, checks != savedChecks, writingHost != nil {
                    guard await savePanelChecklist() else { return }
                }
                let preferences = AssistantPreferences(defaults: defaults)
                let baseConfiguration: AssistantConfiguration
                if let writingHost {
                    try? await writingHost.synchronizeNow()
                    try await WritingPrompts.migrateIfNeeded(host: writingHost, defaults: defaults)
                    let prompt = try await WritingPrompts.effective(host: writingHost, defaults: defaults, purpose: chosenPurpose)
                    if chosenPurpose == .proofreading {
                        let latest = try await WritingPrompts.checklist(host: writingHost)
                        guard !Task.isCancelled, requestID == id else { return }
                        checks = Set(latest.checks); savedChecks = checks
                        checklistBase = try await ProofreadingChecklist.latest(writingHost.records(false))?.id
                    }
                    baseConfiguration = try AssistantConfiguration(endpoint: preferences.endpoint, model: preferences.model(chosenPurpose),
                                                                   prompt: prompt + "\n" + chosenPurpose.requestInstruction)
                } else {
                    baseConfiguration = try preferences.configuration(chosenPurpose)
                }
                guard !Task.isCancelled, requestID == id else { return }
                let manuscript: AssistantManuscript
                if effectiveScope == .current {
                    manuscript = try capture()
                } else {
                    guard let captureScope else { throw AssistantError.emptyContent }
                    manuscript = try captureScope(effectiveScope)
                }
                let checklist = ProofreadingChecklist(selection: checks)
                let referenceDocument = try writingHost?.capture().document ?? document
                let reference = chosenPurpose == .proofreading
                    ? checklist.reference(characters: referenceDocument?.characters ?? [])
                    : referenceDocument.flatMap { AssistantFeedbackContext.reference(document: $0, episodeIDs: effectiveScope.selectedEpisodeIDs(
                        chapters: chapters, currentID: currentEpisodeID
                    ), selected: feedbackContext) }
                let quoted = AssistantManuscript(title: manuscript.title, content: manuscript.content, reference: reference)
                let configuration = try AssistantConfiguration(
                    endpoint: baseConfiguration.endpoint.absoluteString, model: baseConfiguration.model,
                    prompt: baseConfiguration.prompt + "\n" + (chosenPurpose == .proofreading
                        ? checklist.instructions + "\n" + ProofreadingChanges.outputInstruction
                        : "回答はMarkdownで記述してください。"), replacesManuscript: chosenPurpose == .proofreading
                )
                _ = try configuration.request(manuscript: quoted, apiKey: "validation-only")
                pendingPurpose = chosenPurpose; pendingConfiguration = configuration; pending = quoted; notice = nil
            } catch {
                if requestID == id {
                    notice = error.localizedDescription
                }
            }
        }
    }

    private func send() {
        guard !inFlight, let manuscript = pending, let config = pendingConfiguration, let writingHost else { return }
        pending = nil; pendingConfiguration = nil
        do {
            let captured = try writingHost.capture()
            let request = try config.request(manuscript: manuscript, apiKey: "validation-only")
            let metadata = AssistantRequestRecord(purpose: pendingPurpose, documentId: captured.document.id, episodeId: captured.episodeId,
                                                  scope: manuscript.title, permission: pendingPurpose == .proofreading ? "現在の話を校正" : "感想のみ")
            if try writingHost.startRequest(metadata: metadata, input: writingHost.savedInput(request), defaults: defaults) {
                answer = ""; proofreadingResult = nil; notice = nil
            }
        } catch { notice = error.localizedDescription }
    }

    private func loadRequestResults() async {
        guard let writingHost else { return }
        let context = contextID, selectedPurpose = purpose
        do {
            let entries = try await writingHost.recoverInterruptedRequests(writingHost.records(false), defaults: defaults)
            guard context == contextID, selectedPurpose == purpose else { return }
            requestEntries = entries
            guard let latestRequest, let metadata = try? latestRequest.record.decoded(AssistantRequestRecord.self),
                  ["completed", "pending"].contains(metadata.state) else { return }
            if purpose == .proofreading {
                if let id = UUID(uuidString: latestRequest.record.key), let saved = writingHost.proofreadingResult(id: id, defaults: defaults) {
                    let text = (try? capture().content) ?? ""
                    proofreadingResult = try saved.display(on: text, completed: metadata.state == "completed")
                }
            } else {
                answer = try AssistantRecordChunks.text(entries: entries, key: "result:\(latestRequest.record.key)")
            }
        } catch {
            if !Task.isCancelled {
                notice = error.localizedDescription
            }
        }
    }

    private func retry() {
        Task { @MainActor in
            guard let writingHost else { return }
            do {
                let entries = try await writingHost.records(false)
                if let latestRequest {
                    if try await !writingHost.retry(latestRequest.record, entries: entries, defaults: defaults) {
                        prepare()
                    }
                } else if try await !writingHost.retryLatest(key: writingHost.requestKey(purpose: purpose), defaults: defaults) {
                    prepare()
                }
            } catch { notice = error.localizedDescription }
        }
    }

    private func confirmProofreading() async {
        guard let writingHost, let latestRequest else { return }
        do {
            var metadata = try latestRequest.record.decoded(AssistantRequestRecord.self)
            guard metadata.state == "pending", metadata.episodeId == currentEpisodeID else { return }
            guard let id = UUID(uuidString: latestRequest.record.key), let saved = writingHost.proofreadingResult(id: id, defaults: defaults) else {
                throw WritingError.invalidRecord
            }
            let current = try capture()
            guard saved.matches(current.content) else { throw WritingError.changedTarget }
            metadata.detail = try await writingHost.applyProofreadingResult(metadata: metadata, expectedText: current.content, raw: saved.raw, id: id)
            metadata.state = "completed"
            try await writingHost.append(WritingRecord(workId: writingHost.workID, kind: "request", key: latestRequest.record.key,
                                                       parentId: latestRequest.id, payload: WritingRecord.payload(metadata)))
            writingHost.requestCenter.changed(); await loadRequestResults()
        } catch { notice = "本文や対象が変わったため反映できません。変更一覧を確認してください。" }
    }

    private func cancel() {
        requestID = nil; requestTask?.cancel(); requestTask = nil
    }

    private func reset() {
        cancel(); pending = nil; pendingConfiguration = nil; answer = ""; proofreadingResult = nil; notice = nil; requestEntries = []
    }
}
