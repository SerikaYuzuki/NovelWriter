import Foundation
import NovelAI

struct ExperimentalFakeAIProvider: AIProvider {
    let descriptor = AIProviderDescriptor(
        id: AIProviderID(rawValue: "fuminiwa-development-fake"),
        displayName: "開発用Fake",
        destination: "このMac内の決定論的テスト実装",
        modelID: "fuminiwa-fake-proofreader-v1",
        modelDisplayName: "FUMINIWA Fake Proofreader v1",
        sessionStorage: .providerReportedNotUsed,
        trainingUse: .providerReportedNotUsed,
        authentication: .none,
        capabilities: [.streaming, .cancellation, .usageReporting]
    )

    func start(request: AIConfirmedRequest, events: AIProviderEventContinuation) async {
        let cancellation = ExperimentalFakeCancellationFlag()
        events.onUpstreamCancellation {
            cancellation.cancel()
        }
        events.yieldStarted()

        do {
            try await Task.sleep(for: .milliseconds(120))
        } catch {
            events.fail(.cancelled)
            return
        }
        guard !cancellation.isCancelled, !Task.isCancelled else {
            events.fail(.cancelled)
            return
        }

        guard let selectedText = selectedText(from: request.outbound.applicationPrompt),
              let structuredOutput = structuredOutput(for: selectedText) else
        {
            events.fail(.invalidResponse)
            return
        }
        events.yieldReplacementDelta(proofread(selectedText))
        events.complete(
            structuredOutput: structuredOutput,
            usage: AIUsage(inputTokens: nil, outputTokens: 1)
        )
    }

    private func selectedText(from applicationPrompt: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(applicationPrompt.utf8)),
              let envelope = object as? [String: Any] else { return nil }
        return envelope["selected_text"] as? String
    }

    private func proofread(_ source: String) -> String {
        source
            .replacingOccurrences(of: "出来る", with: "できる")
            .replacingOccurrences(of: "。。", with: "。")
    }

    private func structuredOutput(for source: String) -> String? {
        let replacement = proofread(source)
        let changed = replacement != source
        let object: [String: Any] = [
            "replacement": replacement,
            "summary": changed ? "表記を整えました。" : "開発用Fakeでは変更候補を検出しませんでした。",
            "warnings": ["これはUIと安全境界を確認する開発用Fakeの結果です。"]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

private final class ExperimentalFakeCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

extension AIProviderRoute {
    static func developmentFake() -> AIProviderRoute {
        AIProviderRoute(
            provider: ExperimentalFakeAIProvider(),
            disclosure: AIProviderDisclosureSnapshot(
                revision: "development-fake-v1",
                summary: "外部providerへ送信しない、UI検証専用のFakeです。",
                limitations: [
                    "Codex SDKとOpenRouterはまだ接続されていません。",
                    "保持・学習利用の表示は実provider接続時に再確認します。"
                ],
                isDevelopmentFake: true
            )
        )
    }
}
