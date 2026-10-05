import NovelWorkspaceUI
import NovelWritingSupport
import SwiftUI

struct AssistantRequestStatusView: View {
    let host: WritingAssistantHost
    let key: AssistantRequestKey
    let defaults: UserDefaults
    var rebuild: @MainActor () async throws -> Void = {}
    @State private var notice: String?
    var body: some View {
        if let status = host.requestCenter.statuses[key] {
            VStack(alignment: .leading, spacing: 6) {
                if status.inFlight {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(label(status)).font(.caption).monospacedDigit()
                        Button("中止") { host.requestCenter.cancel(key) }
                    }
                    if status.stalled {
                        Label("応答が止まっているようです", systemImage: "exclamationmark.triangle").font(.caption)
                        HStack {
                            Button("待つ") { host.requestCenter.wait(key) }
                            Button("中止") { host.requestCenter.cancel(key, reason: "応答が止まったため中止しました。再送できます。", category: "stalled") }
                            Button("再送") {
                                host.requestCenter.cancel(key, reason: "応答が止まったため中止しました。再送できます。", category: "stalled")
                                Task { @MainActor in
                                    while host.requestCenter.statuses[key]?.inFlight == true {
                                        try? await Task.sleep(for: .seconds(AssistantRuntimeTiming(defaults: defaults, purpose: .advice).tickSeconds))
                                    }
                                    await resend()
                                }
                            }
                        }
                    }
                } else if let failure = status.failure {
                    Text(failure).font(.caption).foregroundStyle(.secondary)
                    Button("再送") { Task { await resend() } }
                }
                if let notice {
                    Text(notice).font(.caption)
                }
            }
        }
    }

    private func resend() async {
        do {
            if try await !host.retryLatest(key: key, defaults: defaults) {
                try await rebuild()
            }
        } catch { notice = error.localizedDescription }
    }

    private func label(_ status: AssistantRequestCenter.Status) -> String {
        let phase = switch status.progress.phase {
        case .queued: "AIへの接続・処理待ち"
        case .working: "AIが回答を作成中"
        case .receiving: "受信中・\(status.progress.characters.formatted())字"
        case .elapsedOnly: "回答待ち"
        }
        return "\(phase)・\(status.elapsedSeconds)秒"
    }
}
