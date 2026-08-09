import Foundation
import NovelAI
import Testing

private let warningLimitDescriptor = AIProviderDescriptor(
    id: .codex,
    displayName: "Codex",
    destination: "OpenAI",
    modelID: "codex-model",
    modelDisplayName: "Codex Model",
    sessionStorage: .notVerified,
    trainingUse: .notVerified,
    authentication: .apiKey,
    capabilities: [.streaming, .cancellation, .usageReporting]
)

private let warningLimitBudget = AIRequestBudget(
    maximumInputCharacters: 2000,
    maximumInputUTF8Bytes: 8000,
    maximumOutputCharacters: 4000,
    maximumOutputUTF8Bytes: 16000,
    maximumOutputTokens: 1000,
    maximumWarnings: AIRequestBudget.absoluteMaximumWarnings,
    timeoutSeconds: 30
)

@Test("注意点はdomain hard limitちょうどまで受け付ける")
func warningCollectionAcceptsAbsoluteLimit() throws {
    let request = try makeWarningLimitRequest()
    let warnings = Array(repeating: "確認", count: AIRequestBudget.absoluteMaximumWarnings)
    let result = AIResult(
        replacement: "校正後",
        summary: "完了",
        warnings: warnings,
        usage: AIUsage(outputTokens: 10)
    )

    #expect(try request.validating(result) == result)
    #expect(
        try request.decodeResult(
            from: structuredOutput(warnings: warnings),
            usage: AIUsage(outputTokens: 10)
        ) == result
    )
}

@Test("注意点の件数超過を値経路とraw JSON経路の両方で拒否する")
func warningCollectionRejectsAboveAbsoluteLimit() throws {
    let request = try makeWarningLimitRequest()
    let actual = AIRequestBudget.absoluteMaximumWarnings + 1
    let warnings = Array(repeating: "確認", count: actual)
    let expected = AIError.outputWarningCountLimitExceeded(
        limit: AIRequestBudget.absoluteMaximumWarnings,
        actual: actual
    )

    expectWarningLimitError(expected) {
        _ = try request.validating(
            AIResult(
                replacement: "校正後",
                summary: "完了",
                warnings: warnings,
                usage: AIUsage(outputTokens: 10)
            )
        )
    }
    expectWarningLimitError(expected) {
        _ = try request.decodeResult(
            from: structuredOutput(warnings: warnings),
            usage: AIUsage(outputTokens: 10)
        )
    }
}

private func makeWarningLimitRequest() throws -> AIConfirmedRequest {
    try AIRequestDraft(selectedText: "校正する本文", budget: warningLimitBudget)
        .preview(for: warningLimitDescriptor)
        .confirmForSending()
}

private func structuredOutput(warnings: [String]) throws -> String {
    let object: [String: Any] = [
        "replacement": "校正後",
        "summary": "完了",
        "warnings": warnings
    ]
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return try #require(String(data: data, encoding: .utf8))
}

private func expectWarningLimitError(_ expected: AIError, operation: () throws -> Void) {
    do {
        try operation()
        Issue.record("Expected AIError: \(expected)")
    } catch let error as AIError {
        #expect(error == expected)
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}
