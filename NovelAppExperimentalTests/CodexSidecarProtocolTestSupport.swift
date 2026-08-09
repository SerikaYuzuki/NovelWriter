import Foundation
@testable import FUMINIWAExperimental
import NovelAI
import Testing

let protocolRequestIDText = "00000000-0000-0000-0000-000000000001"
let protocolRequestID = requiredRequestID(protocolRequestIDText)
let otherProtocolRequestID = requiredRequestID(
    "00000000-0000-0000-0000-000000000002"
)

let codexSidecarDescriptor = AIProviderDescriptor(
    id: .codex,
    displayName: "Codex Test",
    destination: "OpenAI Test",
    modelID: "codex-test-model-v1",
    modelDisplayName: "Codex Test Model",
    sessionStorage: .notVerified,
    trainingUse: .notVerified,
    authentication: .apiKey,
    capabilities: [.streaming, .cancellation, .usageReporting]
)

let codexSidecarBudget = AIRequestBudget(
    maximumInputCharacters: 20000,
    maximumInputUTF8Bytes: 80000,
    maximumOutputCharacters: 20000,
    maximumOutputUTF8Bytes: 80000,
    maximumOutputTokens: 4096,
    maximumWarnings: 20,
    timeoutSeconds: 30
)

let mockRuntimeIdentity = requiredMockRuntimeIdentity()

enum ProtocolBudgetField: CaseIterable {
    case maximumInputCharacters
    case maximumInputUTF8Bytes
    case maximumOutputCharacters
    case maximumOutputUTF8Bytes
    case maximumOutputTokens
    case maximumWarnings
    case timeoutSeconds

    var wireName: String {
        switch self {
        case .maximumInputCharacters: "maximum_input_characters"
        case .maximumInputUTF8Bytes: "maximum_input_utf8_bytes"
        case .maximumOutputCharacters: "maximum_output_characters"
        case .maximumOutputUTF8Bytes: "maximum_output_utf8_bytes"
        case .maximumOutputTokens: "maximum_output_tokens"
        case .maximumWarnings: "maximum_warnings"
        case .timeoutSeconds: "timeout_seconds"
        }
    }

    var maximum: Int {
        switch self {
        case .maximumInputCharacters: CodexSidecarBudget.maximumInputCharacters
        case .maximumInputUTF8Bytes: CodexSidecarBudget.maximumInputUTF8Bytes
        case .maximumOutputCharacters: CodexSidecarBudget.maximumOutputCharacters
        case .maximumOutputUTF8Bytes: CodexSidecarBudget.maximumOutputUTF8Bytes
        case .maximumOutputTokens: CodexSidecarBudget.maximumOutputTokens
        case .maximumWarnings: CodexSidecarBudget.maximumWarnings
        case .timeoutSeconds: CodexSidecarBudget.maximumTimeoutSeconds
        }
    }

    func set(_ value: Int, on values: inout ProtocolBudgetValues) {
        switch self {
        case .maximumInputCharacters: values.maximumInputCharacters = value
        case .maximumInputUTF8Bytes: values.maximumInputUTF8Bytes = value
        case .maximumOutputCharacters: values.maximumOutputCharacters = value
        case .maximumOutputUTF8Bytes: values.maximumOutputUTF8Bytes = value
        case .maximumOutputTokens: values.maximumOutputTokens = value
        case .maximumWarnings: values.maximumWarnings = value
        case .timeoutSeconds: values.timeoutSeconds = value
        }
    }
}

struct ProtocolBudgetValues {
    var maximumInputCharacters: Int
    var maximumInputUTF8Bytes: Int
    var maximumOutputCharacters: Int
    var maximumOutputUTF8Bytes: Int
    var maximumOutputTokens: Int
    var maximumWarnings: Int
    var timeoutSeconds: Int

    static let maximum = Self(
        maximumInputCharacters: CodexSidecarBudget.maximumInputCharacters,
        maximumInputUTF8Bytes: CodexSidecarBudget.maximumInputUTF8Bytes,
        maximumOutputCharacters: CodexSidecarBudget.maximumOutputCharacters,
        maximumOutputUTF8Bytes: CodexSidecarBudget.maximumOutputUTF8Bytes,
        maximumOutputTokens: CodexSidecarBudget.maximumOutputTokens,
        maximumWarnings: CodexSidecarBudget.maximumWarnings,
        timeoutSeconds: CodexSidecarBudget.maximumTimeoutSeconds
    )

    func makeBudget() throws -> CodexSidecarBudget {
        try CodexSidecarBudget(
            maximumInputCharacters: maximumInputCharacters,
            maximumInputUTF8Bytes: maximumInputUTF8Bytes,
            maximumOutputCharacters: maximumOutputCharacters,
            maximumOutputUTF8Bytes: maximumOutputUTF8Bytes,
            maximumOutputTokens: maximumOutputTokens,
            maximumWarnings: maximumWarnings,
            timeoutSeconds: timeoutSeconds
        )
    }
}

func fixtureCommand(named name: String) throws -> CodexSidecarCommand {
    try decodeSingleCommandFrame(fixtureData(named: name))
}

func productionPreview() throws -> AIOutboundPreview {
    try AIRequestDraft(
        selectedText: "出来る。。",
        budget: codexSidecarBudget
    ).preview(for: codexSidecarDescriptor)
}

func sessionAfterStart() throws -> CodexSidecarHostSessionState {
    var session = CodexSidecarHostSessionState(
        requestID: protocolRequestID,
        expectedRuntime: mockRuntimeIdentity
    )
    _ = try session.encodeHelloFrame()
    try session.accept(.ready(requestID: protocolRequestID, runtime: mockRuntimeIdentity))
    _ = try session.encodeStartFrame(applicationPayload: productionPreview().applicationPayload)
    return session
}

func directStart(
    modelID: String = "codex-test-model-v1",
    instructionID: String = "proofreading-selection-v1",
    prompt: String = "test",
    schemaID: String = "proofreading-result-v1",
    schema: String = "{}"
) throws -> CodexSidecarStartCommand {
    try CodexSidecarStartCommand(
        requestID: protocolRequestID,
        modelID: modelID,
        applicationInstructionID: instructionID,
        applicationPrompt: prompt,
        applicationResponseSchemaID: schemaID,
        applicationResponseSchema: schema,
        budget: CodexSidecarBudget(codexSidecarBudget),
        inputCharacterCount: prompt.count + schema.count,
        inputUTF8ByteCount: prompt.utf8.count + schema.utf8.count
    )
}

func decodeStartFixture(
    replacing field: String,
    with value: Any
) throws -> CodexSidecarCommand {
    let fixture = try fixtureData(named: "start")
    var object = try #require(
        JSONSerialization.jsonObject(with: fixture) as? [String: Any]
    )
    object[field] = value
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    let frame = try #require(String(data: data, encoding: .utf8))
    return try CodexSidecarMessageCodec.decodeCommand(frame: frame)
}

func sdkRuntimeIdentity(
    nodeSHA256: String,
    sdkIntegrity: String
) throws -> CodexSidecarRuntimeIdentity {
    let hash = String(repeating: "a", count: 64)
    return try CodexSidecarRuntimeIdentity(
        mode: .codexSDK,
        sidecarVersion: "1.0.0",
        sidecarBundleSHA256: hash,
        nodeVersion: "22.0.0",
        nodeSHA256: nodeSHA256,
        architecture: .arm64,
        sdkVersion: "0.147.0",
        sdkIntegrity: sdkIntegrity,
        cliVersion: "0.147.0",
        cliSHA256: hash
    )
}

func expectJSONFramesEquivalent(_ lhs: Data, _ rhs: Data) throws {
    #expect(try canonicalJSON(lhs) == canonicalJSON(rhs))
}

func canonicalJSON(_ frame: Data) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: frame)
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

func nestedJSONObject(depth: Int) -> String {
    String(repeating: #"{"value":"#, count: depth) + "0" +
        String(repeating: "}", count: depth)
}

func nestedEmptyJSONContainer(
    opening: String,
    closing: String,
    depth: Int,
    emptyValue: String
) -> String {
    String(repeating: opening, count: depth - 1) + emptyValue +
        String(repeating: closing, count: depth - 1)
}

func expectMalformedJSONScanner(_ scanner: inout CodexStrictJSONScanner) {
    do {
        try scanner.validate()
        Issue.record("Expected malformed JSON scanner error")
    } catch CodexStrictJSONScanner.ScanError.malformed {
        // Expected.
    } catch {
        Issue.record("Unexpected scanner error: \(error)")
    }
}

func fixtureEvent(named name: String) throws -> CodexSidecarEvent {
    try decodeSingleEventFrame(fixtureData(named: name))
}

func roundTrippedFixtureEvent(named name: String) throws -> CodexSidecarEvent {
    let event = try fixtureEvent(named: name)
    let encoded = try CodexSidecarMessageCodec.encodeEventFrame(event)
    #expect(try decodeSingleEventFrame(encoded) == event)
    return event
}

func startedEventFrame(
    version: String = "1",
    requestID: String = protocolRequestIDText,
    extraMembers: String = ""
) -> String {
    #"{"version":\#(version),"type":"started","request_id":"\#(requestID)""# +
        extraMembers + "}"
}

func completedEventFrame(
    structuredOutput: String = "{}",
    inputTokens: String = "null",
    outputTokens: String = "0"
) -> String {
    #"{"version":1,"type":"completed","request_id":"\#(protocolRequestIDText)","# +
        #""structured_output":"\#(structuredOutput)","usage":{"input_tokens":\#(inputTokens),"# +
        #""output_tokens":\#(outputTokens)}}"#
}

func failedEventFrame(code: String) -> String {
    #"{"version":1,"type":"failed","request_id":"\#(protocolRequestIDText)","# +
        #""code":"\#(code)"}"#
}

func decodeSingleCommandFrame(_ data: Data) throws -> CodexSidecarCommand {
    let frame = try singleFrame(from: data)
    return try CodexSidecarMessageCodec.decodeCommand(frame: frame)
}

func decodeSingleEventFrame(_ data: Data) throws -> CodexSidecarEvent {
    let frame = try singleFrame(from: data)
    return try CodexSidecarMessageCodec.decodeEvent(frame: frame)
}

func singleFrame(from data: Data) throws -> String {
    var decoder = CodexSidecarFrameDecoder()
    let frames = try decoder.append(data)
    try decoder.finish()
    return try #require(frames.count == 1 ? frames[0] : nil)
}

func fixtureData(named name: String) throws -> Data {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let fixtureURL = repositoryRoot
        .appendingPathComponent("Sidecars", isDirectory: true)
        .appendingPathComponent("Codex", isDirectory: true)
        .appendingPathComponent("fixtures", isDirectory: true)
        .appendingPathComponent("protocol-v1", isDirectory: true)
        .appendingPathComponent("\(name).jsonl")
    return try Data(contentsOf: fixtureURL)
}

func requiredRequestID(_ rawValue: String) -> CodexSidecarRequestID {
    do {
        return try CodexSidecarRequestID(validating: rawValue)
    } catch {
        fatalError("Invalid test request ID: \(rawValue)")
    }
}

func requiredMockRuntimeIdentity() -> CodexSidecarRuntimeIdentity {
    do {
        return try CodexSidecarRuntimeIdentity(
            mode: .mock,
            sidecarVersion: "protocol-v1-test",
            sidecarBundleSHA256: nil,
            nodeVersion: "0.0.0-test",
            nodeSHA256: nil,
            architecture: .arm64,
            sdkVersion: nil,
            sdkIntegrity: nil,
            cliVersion: nil,
            cliSHA256: nil
        )
    } catch {
        fatalError("Invalid mock runtime identity")
    }
}

func expectSidecarError(
    _ expected: CodexSidecarLocalError,
    operation: () throws -> Void
) {
    do {
        try operation()
        Issue.record("Expected CodexSidecarLocalError: \(expected)")
    } catch let error as CodexSidecarLocalError {
        #expect(error == expected)
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}
