@testable import NovelAI
import Testing

private let strictJSONProvider = AIProviderDescriptor(
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

private let strictJSONBudget = AIRequestBudget(
    maximumInputCharacters: 2000,
    maximumInputUTF8Bytes: 8000,
    maximumOutputCharacters: 4000,
    maximumOutputUTF8Bytes: 16000,
    maximumOutputTokens: 1000,
    timeoutSeconds: 30
)

@Test("raw structured outputのroot duplicate memberを拒否する")
func rawStructuredOutputRejectsDuplicateRootMembers() throws {
    let request = try makeStrictJSONRequest()
    let duplicateMembers = [
        #"{"replacement":"先","replacement":"後","summary":"要約","warnings":[]}"#,
        #"{"replacement":"案","summary":"要約","warnings":[],"warnings":["重複"]}"#
    ]

    for output in duplicateMembers {
        expectStrictScannerRejected(output)
        expectInvalidResponse(output, request: request)
    }
}

@Test("escape後に衝突するroot memberとnested memberを拒否する")
func rawStructuredOutputRejectsEscapedMemberCollisions() throws {
    let request = try makeStrictJSONRequest()
    let escapedCollisions = [
        #"{"replacement":"先","\u0072eplacement":"後","summary":"要約","warnings":[]}"#,
        #"{"replacement":"案","summary":"要約","warnings":[{"key":"先","\u006bey":"後"}]}"#
    ]

    for output in escapedCollisions {
        expectStrictScannerRejected(output)
        expectInvalidResponse(output, request: request)
    }

    var distinctNestedMembers = AIStrictJSONScanner(
        #"{"outer":{"key":"先","\u006fther":"後"}}"#
    )
    try distinctNestedMembers.validate()
}

@Test("raw structured outputのunpaired UTF-16 surrogateを拒否する")
func rawStructuredOutputRejectsUnpairedSurrogates() throws {
    let request = try makeStrictJSONRequest()
    let unpairedSurrogates = [
        #"{"replacement":"\uD800","summary":"要約","warnings":[]}"#,
        #"{"replacement":"\uDC00","summary":"要約","warnings":[]}"#,
        #"{"replacement":"\uD800\u0041","summary":"要約","warnings":[]}"#
    ]

    for output in unpairedSurrogates {
        expectStrictScannerRejected(output)
        expectInvalidResponse(output, request: request)
    }
}

@Test("paired surrogateとexact response schemaは従来どおりdecodeできる")
func pairedSurrogateAndExactSchemaRemainValid() throws {
    let request = try makeStrictJSONRequest()
    let result = try request.decodeResult(
        from: #"{"replacement":"\uD83D\uDE00","summary":"修正","warnings":["\u78BA\u8A8D"]}"#,
        usage: AIUsage(inputTokens: 4, outputTokens: 3)
    )

    #expect(
        result == AIResult(
            replacement: "😀",
            summary: "修正",
            warnings: ["確認"],
            usage: AIUsage(inputTokens: 4, outputTokens: 3)
        )
    )
}

@Test("JSON container depthは64を許可し65を拒否する")
func strictJSONScannerEnforcesContainerDepthBoundary() {
    let accepted = nestedArray(depth: AIStrictJSONScanner.maximumContainerDepth)
    var acceptedScanner = AIStrictJSONScanner(accepted)
    do {
        try acceptedScanner.validate()
    } catch {
        Issue.record("depth 64のvalid JSONを拒否しました: \(error)")
    }

    let rejected = nestedArray(depth: AIStrictJSONScanner.maximumContainerDepth + 1)
    expectStrictScannerRejected(rejected)
}

@Test("decodeResultはdepth 65のraw structured outputをinvalidResponseにする")
func rawStructuredOutputRejectsDepthOverLimit() throws {
    let request = try makeStrictJSONRequest()
    expectInvalidResponse(
        nestedArray(depth: AIStrictJSONScanner.maximumContainerDepth + 1),
        request: request
    )
}

private func makeStrictJSONRequest() throws -> AIConfirmedRequest {
    try AIRequestDraft(selectedText: "校正対象", budget: strictJSONBudget)
        .preview(for: strictJSONProvider)
        .confirmForSending()
}

private func nestedArray(depth: Int) -> String {
    String(repeating: "[", count: depth) + "0" + String(repeating: "]", count: depth)
}

private func expectStrictScannerRejected(_ output: String) {
    var scanner = AIStrictJSONScanner(output)
    do {
        try scanner.validate()
        Issue.record("strict JSON scannerが不正JSONを受理しました")
    } catch {
        // expected
    }
}

private func expectInvalidResponse(_ output: String, request: AIConfirmedRequest) {
    do {
        _ = try request.decodeResult(
            from: output,
            usage: AIUsage(inputTokens: 4, outputTokens: 3)
        )
        Issue.record("AIError.invalidResponseを期待しました")
    } catch let error as AIError {
        #expect(error == .invalidResponse)
    } catch {
        Issue.record("想定外のerror型です: \(error)")
    }
}
