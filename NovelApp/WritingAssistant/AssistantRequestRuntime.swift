import Foundation
import NovelCore
import NovelWorkspaceUI
import NovelWritingSupport

@MainActor
final class AssistantPreparation {
    var input: (AssistantRequestRecord, String)?
    var candidate: WritingRecord?
}

@MainActor
extension WritingAssistantHost {
    func requestKey(purpose: AssistantPurpose, conversation: UUID? = nil) -> AssistantRequestKey {
        AssistantRequestKey(work: workID, account: accountID, lane: conversation?.uuidString ?? purpose.id)
    }

    /// Retry data excludes endpoint/model/credentials. The explicit retry reads current device settings.
    func savedInput(_ request: URLRequest) throws -> String {
        guard let data = request.httpBody, var body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AssistantError.invalidConfiguration
        }
        body.removeValue(forKey: "model"); body.removeValue(forKey: "stream"); body.removeValue(forKey: "store")
        return try String(decoding: JSONSerialization.data(withJSONObject: body), as: UTF8.self)
    }

    @discardableResult
    func startRequest(metadata: AssistantRequestRecord, input: String, defaults: UserDefaults, id: UUID = UUID(),
                      prepare: @escaping @MainActor (UUID) async throws -> Void = { _ in },
                      preparedInput: (@MainActor (UUID) async throws -> (AssistantRequestRecord, String))? = nil,
                      preparation: AssistantPreparation = AssistantPreparation()) -> Bool {
        let key = requestKey(purpose: metadata.purpose, conversation: metadata.conversationId)
        let timing = AssistantRuntimeTiming(defaults: defaults, purpose: metadata.purpose)
        var started: WritingRecord?
        var terminal = metadata
        let admitted = requestCenter.start(key: key, id: id, timing: timing, operation: { id, progress in
            _ = try await withBackgroundTime {
                if preparation.input == nil {
                    preparation.input = try await preparedInput?(id) ?? (metadata, input)
                }
                let (metadata, input) = preparation.input!
                terminal = metadata
                try await prepare(id)
                if preparation.candidate == nil {
                    preparation.candidate = try WritingRecord(workId: workID, kind: "request", key: id.uuidString.lowercased(), payload: WritingRecord.payload(metadata))
                }
                var local = defaults.stringArray(forKey: Self.localRequestsKey) ?? []
                if !local.contains(id.uuidString.lowercased()) {
                    local.append(id.uuidString.lowercased())
                }
                defaults.set(local, forKey: Self.localRequestsKey)
                let record = preparation.candidate!
                try await append(record); started = record
                // Retain the prepared input only in this process, including after a failed send.
                requestCenter.unsentRetries[key] = { [self] in
                    var retry = metadata; retry.state = "sent"; retry.detail = nil
                    _ = startRequest(metadata: retry, input: input, defaults: defaults)
                }
                let raw = try await transmit(input, metadata.purpose, defaults, timing.maxSeconds, progress)
                try Task.checkCancellation()
                let result: String
                if metadata.purpose == .advice {
                    guard raw.utf8.count <= 900_000 else { throw AssistantError.tooLarge }
                    let answer = metadata.grant.paths.isEmpty ? nil : try JSONDecoder().decode(AssistantChatAnswer.self, from: Data(raw.utf8))
                    result = answer?.reply ?? raw
                    if let conversation = metadata.conversationId {
                        try await append(WritingRecord(workId: workID, kind: "message", key: conversation.uuidString.lowercased(),
                                                       payload: WritingRecord.payload(WritingMessage(role: "assistant", text: result, requestId: id))))
                    }
                    if let answer, !answer.changes.isEmpty {
                        let edit = try WritingEdit(id: id, workId: workID, documentId: metadata.documentId, changes: answer.changes.map { try $0.change() })
                        try await appendEdit(edit)
                        do {
                            try await apply(edit, metadata.grant)
                            terminal.detail = "指定した範囲に反映しました。取り消しできます。"
                            if let conversation = metadata.conversationId {
                                try await append(WritingRecord(workId: workID, kind: "message", key: conversation.uuidString.lowercased(),
                                                               payload: WritingRecord.payload(WritingMessage(role: "assistant", text: Self.editSummary(edit), requestId: id))))
                            }
                        } catch {
                            terminal.state = "pending"; terminal.detail = "変更案を会話に保存しました。\(error.localizedDescription)"
                        }
                    }
                } else {
                    result = raw
                    if metadata.purpose == .proofreading {
                        _ = try AssistantClient.proofreadChanges(raw)
                    }
                }
                if metadata.purpose == .impressions {
                    for record in try AssistantRecordChunks.records(text: result, key: "result:\(id.uuidString.lowercased())", work: workID) {
                        try await append(record)
                    }
                }
                if metadata.purpose == .proofreading {
                    try saveProofreadingResult(raw: result, input: input, id: id, defaults: defaults)
                    terminal.state = "pending"
                    do {
                        terminal.detail = try await applyProofreadingResult(metadata: metadata, input: input, raw: result, id: id)
                        terminal.state = "completed"
                    } catch { terminal.detail = "未反映の校正結果があります。戻ってから確認してください。" }
                } else if terminal.state == "sent" {
                    terminal.state = "completed"
                }
                return ""
            }
        }, ended: { id, failure in
            if failure == nil {
                requestCenter.unsentRetries[key] = nil
            }
            guard let started else { return }
            if let failure {
                terminal.state = "interrupted"; terminal.detail = failure
            }
            let record = WritingRecord(workId: workID, kind: "request", key: id.uuidString.lowercased(), parentId: started.id,
                                       payload: (try? WritingRecord.payload(terminal)) ?? started.payload)
            // Cancellation must not prevent a terminal record. Account/work guards still apply.
            try await Task { @MainActor in try await append(record) }.value
        })
        if admitted {
            requestCenter.unsentRetries[key] = { [self] in
                _ = startRequest(metadata: metadata, input: input, defaults: defaults, id: id,
                                 prepare: prepare, preparedInput: preparedInput, preparation: preparation)
            }
        }
        return admitted
    }

    /// False means this process has no input: the caller must prepare from current data.
    @discardableResult
    func retry(_ record: WritingRecord, entries _: [WritingEnvelope], defaults _: UserDefaults) async throws -> Bool {
        let metadata = try record.decoded(AssistantRequestRecord.self)
        guard record.workId == workID, ["interrupted", "failed", "cancelled", "sent"].contains(metadata.state) else { return false }
        if let id = UUID(uuidString: record.key), let state = try await editState(id), ["applied", "prepared"].contains(state) {
            throw WritingError.alreadyApplied
        }
        let current = try capture()
        guard current.document.id == metadata.documentId else { throw WritingError.changedScope }
        return requestCenter.retryUnsent(requestKey(purpose: metadata.purpose, conversation: metadata.conversationId))
    }

    @discardableResult
    func retryLatest(key: AssistantRequestKey, defaults _: UserDefaults) async throws -> Bool {
        guard key.work == workID, key.account == accountID, requestCenter.statuses[key]?.inFlight != true else { return false }
        return requestCenter.retryUnsent(key)
    }

    func applyProofreadingResult(metadata: AssistantRequestRecord, input: String, raw: String, id: UUID) async throws -> String {
        try await applyProofreadingResult(metadata: metadata, expectedText: manuscript(input).content, raw: raw, id: id)
    }

    func applyProofreadingResult(metadata: AssistantRequestRecord, expectedText: String, raw: String, id: UUID) async throws -> String {
        let current = try await captureWhenReady()
        guard current.workId == workID, current.document.id == metadata.documentId, current.episodeId == metadata.episodeId,
              let path = current.episodePath else { throw WritingError.changedScope }
        guard let episode = current.document.chapters.flatMap(\.episodes).first(where: { $0.id == metadata.episodeId }),
              episode.content == expectedText else { throw WritingError.changedTarget }
        let revision = try AssistantClient.proofreadChanges(raw).application(to: expectedText)
        guard !revision.accepted.isEmpty else { return revision.rejected.isEmpty ? "修正はありませんでした。" : "適用できる提案はありませんでした。変更一覧を確認してください。" }
        let edit = try WritingEdit(id: id, workId: workID, documentId: metadata.documentId,
                                   changes: [WritingChange(path: path + ["content"], before: .string(expectedText), after: .string(revision.replacement))])
        rememberProofreadingEdit(id, defaults: defaults)
        try await applyExactProofreading(edit, WritingGrant(paths: [path + ["content"]]), episode.id, expectedText)
        return "校正を反映しました。追加・変更箇所を黄色で表示しています。保存で色を消せます。取り消しも可能です。"
    }

    func manuscript(_ input: String) throws -> AssistantManuscript {
        guard let body = try JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any] else { throw WritingError.invalidRecord }
        let quoted = body["input"] as? String ?? (body["messages"] as? [[String: Any]])?.last?["content"] as? String
        guard let quoted else { throw WritingError.invalidRecord }
        return try JSONDecoder().decode(AssistantManuscript.self, from: Data(quoted.utf8))
    }

    func recoverInterruptedRequests(_ entries: [WritingEnvelope], defaults: UserDefaults) async throws -> [WritingEnvelope] {
        var recovered = entries
        for item in AssistantRequestRecord.latest(entries) {
            guard var metadata = try? item.record.decoded(AssistantRequestRecord.self), metadata.state == "sent",
                  interrupted(item.record, defaults: defaults), !requestCenter.recoveredRequestIDs.contains(item.id) else { continue }
            requestCenter.recoveredRequestIDs.insert(item.id)
            let edit = UUID(uuidString: item.record.key)
            let state: String? = if let edit {
                try await editState(edit)
            } else {
                nil
            }
            if state == "applied" {
                metadata.state = "completed"; metadata.detail = "前回の依頼は反映済みです。変更履歴から取り消せます。"
            } else if state == "prepared" {
                metadata.state = "pending"; metadata.detail = "前回の編集の完了を確認できません。変更履歴から確認してください。"
            } else if let edit, metadata.purpose == .proofreading, proofreadingResult(id: edit, defaults: defaults) != nil {
                metadata.state = "pending"; metadata.detail = "未反映の校正結果があります。確認してから反映してください。"
            } else {
                metadata.state = "interrupted"; metadata.detail = "前回の起動中に依頼が中断しました。現在の内容で再送できます。"
            }
            let record = try WritingRecord(workId: workID, kind: "request", key: item.record.key, parentId: item.id, payload: WritingRecord.payload(metadata))
            do { try await append(record); recovered.append(WritingEnvelope(record: record)) }
            catch { requestCenter.recoveredRequestIDs.remove(item.id); throw error }
        }
        return recovered
    }

    func interrupted(_ record: WritingRecord, defaults: UserDefaults) -> Bool {
        (defaults.stringArray(forKey: Self.localRequestsKey) ?? []).contains(record.key)
            && !requestCenter.isRunning(UUID(uuidString: record.key) ?? record.id)
    }

    static let localRequestsKey = "assistant.localRequestIDs"

    private static func editSummary(_ edit: WritingEdit) -> String {
        let added = edit.changes.reduce(0) { count, change in
            if case let .string(before)? = change.before, case let .string(after)? = change.after {
                return count + max(0, after.count - before.count)
            }
            return count
        }
        return added > 0 ? "（この依頼で約\(added)字追加・\(edit.changes.count)箇所変更）" : "（この依頼で\(edit.changes.count)箇所変更）"
    }
}

@MainActor
enum AssistantTransport {
    static func sendSaved(_ input: String, purpose: AssistantPurpose, defaults: UserDefaults, maxSeconds: Double,
                          progress: @escaping @MainActor (AssistantProgress) -> Void) async throws -> String {
        let preferences = AssistantPreferences(defaults: defaults)
        let config = try preferences.configuration(purpose)
        let apiKey = try preferences.key(endpoint: config.endpoint)
        guard var body = try JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any] else { throw AssistantError.invalidConfiguration }
        body["model"] = config.model; body["store"] = false
        var request = URLRequest(url: config.requestEndpoint)
        request.httpMethod = "POST"; request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        guard request.httpBody!.count <= 2_000_000 else { throw AssistantError.tooLarge }
        return try await AssistantClient.send(request, maxSeconds: maxSeconds, progress: progress)
    }
}
