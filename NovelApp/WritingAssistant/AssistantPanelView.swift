import NovelCore
import NovelUI
import NovelWorkspaceUI
import NovelWritingSupport
import SwiftUI

/// Requests expire on context change; the host owns guarded native-editor application.
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
    @State private var unsavedFeedback: AssistantFeedback?
    @State private var isSavingFeedback = false
    @State private var notice: String?
    @State private var pending: AssistantManuscript?
    @State private var pendingConfiguration: AssistantConfiguration?
    #if os(iOS)
    @State private var showingSettings = false
    #endif
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
                ForEach(AssistantPurpose.allCases.filter { $0 != .advice || writingHost != nil }) { Text($0.rawValue).tag($0) }
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
                    }.disabled(requestTask != nil || isSavingChecklist || (writingHost != nil && !checklistLoaded))
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
                        .disabled(requestTask != nil || isSavingChecklist || (purpose == .proofreading && writingHost != nil && !checklistLoaded) || effectiveScope.selectedEpisodeIDs(
                            chapters: chapters, currentID: currentEpisodeID
                        ).isEmpty)
                    if writingHost != nil {
                        Button("指示") { showingPrompts = true }.disabled(requestTask != nil || isSavingChecklist)
                    }
                    if requestTask != nil {
                        ProgressView().controlSize(.small)
                        Button("中止") { cancel(); notice = "中止しました。" }
                    }
                }
                if let notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
                if unsavedFeedback != nil {
                    Button(isSavingFeedback ? "保存中…" : "回答を保存し直す") {
                        Task { await persistFeedback() }
                    }.disabled(isSavingFeedback)
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
        .task(id: contextID) { await loadChecklist() }
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
                    Text("回答は「感想」に日時付きで保存し、作品と一緒に同期します。")
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
        .onChange(of: purpose) { _, _ in reset() }
        .onChange(of: scope) { _, _ in reset() }
        .onChange(of: chapters.map { $0.id.description + $0.episodes.map(\.id.description).joined() }) { _, _ in reset(); scope = .current }
        .onDisappear { reset() }
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
        guard let manuscript = pending, let config = pendingConfiguration else { return }
        pending = nil
        pendingConfiguration = nil
        do {
            let key = try AssistantPreferences(defaults: defaults).key(endpoint: config.endpoint)
            let requestPurpose = pendingPurpose
            let shouldApply = canApplyProofreading
            let effectiveConfig = config
            let request = try effectiveConfig.request(manuscript: manuscript, apiKey: key)
            let id = UUID()
            requestID = id
            answer = ""; proofreadingResult = nil
            requestTask = Task { @MainActor in
                defer {
                    if requestID == id {
                        requestTask = nil
                    }
                }
                do {
                    if let writingHost {
                        struct RequestRecord: Encodable { let state: String; let effectivePrompt: String; let purpose: String }
                        try await writingHost.append(WritingRecord(
                            workId: writingHost.capture().workId,
                            kind: "request",
                            key: id.uuidString.lowercased(),
                            payload: WritingRecord.payload(RequestRecord(
                                state: "sent",
                                effectivePrompt: effectiveConfig.prompt,
                                purpose: requestPurpose.id
                            ))
                        ))
                    }
                    let result = try await AssistantClient.send(request)
                    guard !Task.isCancelled, requestID == id else { return }
                    if requestPurpose == .proofreading {
                        let revision = try AssistantClient.proofreadChanges(result).application(to: manuscript.content)
                        proofreadingResult = revision
                        guard shouldApply, let applyProofreading else {
                            notice = "変更案を表示しました。本文への反映はできません。"
                            return
                        }
                        guard !revision.accepted.isEmpty else {
                            notice = revision.rejected.isEmpty ? "修正はありませんでした。" : "適用できる提案はありませんでした。"
                            return
                        }
                        guard applyProofreading(manuscript, revision.replacement) else {
                            notice = "本文や対象が変わったため反映しませんでした。入力を確定して再実行してください。"
                            return
                        }
                        notice = revision.replacement == manuscript.content ? "本文の変更はありませんでした。" : "校正を反映しました。追加・変更箇所を黄色で表示しています。削除箇所には色が付きません。保存で色を消せます。取り消しも可能です。"
                    } else {
                        answer = result
                        if requestPurpose == .impressions {
                            unsavedFeedback = AssistantFeedback(id: UUID(), purpose: requestPurpose,
                                                                scopeTitle: manuscript.title, createdAt: Date(), markdown: result)
                            await persistFeedback()
                        }
                    }
                } catch {
                    guard !Task.isCancelled, requestID == id else { return }
                    notice = (error as? AssistantError)?.localizedDescription ?? "通信できませんでした。接続を確認して再試行してください。"
                }
            }
        } catch { notice = error.localizedDescription }
    }

    private func persistFeedback() async {
        guard let feedback = unsavedFeedback, let saveFeedback, !isSavingFeedback else { return }
        isSavingFeedback = true
        defer { isSavingFeedback = false }
        let saved = await saveFeedback(feedback)
        guard unsavedFeedback?.id == feedback.id else { return }
        if saved {
            unsavedFeedback = nil
            notice = "「感想」に保存しました。"
        } else {
            notice = "回答を保存できませんでした。入力を確定して「回答を保存し直す」を押してください。"
        }
    }

    private func cancel() {
        requestID = nil; requestTask?.cancel(); requestTask = nil
    }

    private func reset() {
        cancel(); pending = nil; pendingConfiguration = nil; answer = ""; proofreadingResult = nil; notice = nil; unsavedFeedback = nil
    }
}
