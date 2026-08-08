import Foundation
@testable import FUMINIWAExperimental
import NovelAI
import Testing

@Test("protocol v1の全golden fixtureをstrict codecで読み書きできる")
func goldenProtocolFixturesRoundTrip() throws {
    let helloCommand = try fixtureCommand(named: "hello")
    #expect(helloCommand == .hello(CodexSidecarHelloCommand(requestID: protocolRequestID)))
    #expect(
        try decodeSingleCommandFrame(CodexSidecarMessageCodec.encodeCommandFrame(helloCommand)) ==
            helloCommand
    )

    let startCommand = try fixtureCommand(named: "start")
    guard case let .start(start) = startCommand else {
        Issue.record("start fixture must contain a start command")
        return
    }
    #expect(start.requestID == protocolRequestID)
    #expect(start.modelID == "codex-test-model-v1")
    #expect(start.applicationInstructionID == "proofreading-selection-v1")
    #expect(start.applicationResponseSchemaID == "proofreading-result-v1")
    #expect(
        start.inputUTF8ByteCount ==
            start.applicationPrompt.utf8.count + start.applicationResponseSchema.utf8.count
    )
    expectSidecarError(.startBeforeAttestation) {
        _ = try CodexSidecarMessageCodec.encodeCommandFrame(startCommand)
    }

    let cancelCommand = try fixtureCommand(named: "cancel")
    #expect(cancelCommand == .cancel(CodexSidecarCancelCommand(requestID: protocolRequestID)))
    #expect(
        try decodeSingleCommandFrame(CodexSidecarMessageCodec.encodeCommandFrame(cancelCommand)) ==
            cancelCommand
    )

    let ready = try roundTrippedFixtureEvent(named: "ready")
    #expect(ready == .ready(requestID: protocolRequestID, runtime: mockRuntimeIdentity))

    let started = try roundTrippedFixtureEvent(named: "started")
    #expect(started == .started(requestID: protocolRequestID))

    let completed = try roundTrippedFixtureEvent(named: "completed")
    #expect(
        try completed == .completed(
            requestID: protocolRequestID,
            structuredOutput: #"{"replacement":"test","summary":"ok","warnings":[]}"#,
            usage: CodexSidecarUsage(inputTokens: 2, outputTokens: 3)
        )
    )

    let failed = try roundTrippedFixtureEvent(named: "failed")
    #expect(failed == .failed(requestID: protocolRequestID, code: .providerUnavailable))
}

@Test("confirmed application payloadを追加情報なしでstartへ写像する")
func confirmedPayloadMapsExactlyToStart() throws {
    let preview = try AIRequestDraft(
        selectedText: "結合文字e\u{301}と家族👨‍👩‍👧‍👦",
        budget: codexSidecarBudget
    ).preview(for: codexSidecarDescriptor)

    let start = try CodexSidecarStartCommand(
        requestID: protocolRequestID,
        applicationPayload: preview.applicationPayload
    )

    #expect(start.requestID == protocolRequestID)
    #expect(start.modelID == preview.provider.modelID)
    #expect(start.applicationInstructionID == preview.applicationInstructionID)
    #expect(start.applicationPrompt == preview.applicationPrompt)
    #expect(start.applicationResponseSchemaID == preview.applicationResponseSchemaID)
    #expect(start.applicationResponseSchema == preview.applicationResponseSchema)
    #expect(start.inputCharacterCount == preview.inputCharacterCount)
    #expect(start.inputUTF8ByteCount == preview.inputUTF8ByteCount)
    #expect(start.budget.maximumOutputTokens == preview.budget.maximumOutputTokens)

    var session = CodexSidecarHostSessionState(
        requestID: protocolRequestID,
        expectedRuntime: mockRuntimeIdentity
    )
    _ = try session.encodeHelloFrame()
    try session.accept(.ready(requestID: protocolRequestID, runtime: mockRuntimeIdentity))
    let encoded = try session.encodeStartFrame(applicationPayload: preview.applicationPayload)
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(encoded.dropLast())) as? [String: Any]
    )
    #expect(
        Set(object.keys) == [
            "version",
            "type",
            "request_id",
            "provider_id",
            "model_id",
            "application_instruction_id",
            "application_prompt",
            "application_response_schema_id",
            "application_response_schema",
            "budget",
            "input_character_count",
            "input_utf8_byte_count"
        ]
    )
    #expect(object["application_prompt"] as? String == preview.applicationPrompt)
    #expect(
        object["application_response_schema"] as? String == preview.applicationResponseSchema
    )
}

@Test("start goldenはproduction NovelAI previewの全application値と一致する")
func goldenStartAnchorsProductionPreview() throws {
    let preview = try AIRequestDraft(
        selectedText: "出来る。。",
        budget: codexSidecarBudget
    ).preview(for: codexSidecarDescriptor)
    let fixture = try fixtureCommand(named: "start")
    guard case let .start(start) = fixture else {
        Issue.record("start fixture must contain a start command")
        return
    }

    #expect(start.modelID == preview.provider.modelID)
    #expect(start.applicationInstructionID == preview.applicationInstructionID)
    #expect(start.applicationPrompt == preview.applicationPrompt)
    #expect(start.applicationResponseSchemaID == preview.applicationResponseSchemaID)
    #expect(start.applicationResponseSchema == preview.applicationResponseSchema)
    #expect(try start.budget == CodexSidecarBudget(preview.budget))
    #expect(start.inputCharacterCount == preview.inputCharacterCount)
    #expect(start.inputUTF8ByteCount == preview.inputUTF8ByteCount)

    var session = CodexSidecarHostSessionState(
        requestID: protocolRequestID,
        expectedRuntime: mockRuntimeIdentity
    )
    let helloFrame = try session.encodeHelloFrame()
    try expectJSONFramesEquivalent(helloFrame, fixtureData(named: "hello"))
    try session.accept(fixtureEvent(named: "ready"))
    let startFrame = try session.encodeStartFrame(
        applicationPayload: preview.applicationPayload
    )
    try expectJSONFramesEquivalent(startFrame, fixtureData(named: "start"))
}

@Test("protocol v1 budgetは全7 fieldで0を拒否しmaxを受理しmax+1を拒否する")
func protocolBudgetBoundariesAreIndependentAndExact() throws {
    #expect(CodexSidecarBudget.maximumInputCharacters == 20000)
    #expect(CodexSidecarBudget.maximumInputUTF8Bytes == 80000)
    #expect(CodexSidecarBudget.maximumOutputCharacters == 20000)
    #expect(CodexSidecarBudget.maximumOutputUTF8Bytes == 80000)
    #expect(CodexSidecarBudget.maximumOutputTokens == 8192)
    #expect(CodexSidecarBudget.maximumWarnings == 20)
    #expect(CodexSidecarBudget.maximumTimeoutSeconds == 120)
    #expect(
        AIRequestBudget.absoluteMaximumInputCharacters ==
            CodexSidecarBudget.maximumInputCharacters
    )
    #expect(
        AIRequestBudget.absoluteMaximumInputUTF8Bytes ==
            CodexSidecarBudget.maximumInputUTF8Bytes
    )
    #expect(
        AIRequestBudget.absoluteMaximumOutputCharacters ==
            CodexSidecarBudget.maximumOutputCharacters
    )
    #expect(
        AIRequestBudget.absoluteMaximumOutputUTF8Bytes ==
            CodexSidecarBudget.maximumOutputUTF8Bytes
    )
    #expect(AIRequestBudget.absoluteMaximumOutputTokens == CodexSidecarBudget.maximumOutputTokens)
    #expect(AIRequestBudget.absoluteMaximumWarnings == CodexSidecarBudget.maximumWarnings)
    #expect(
        AIRequestBudget.absoluteMaximumTimeoutSeconds ==
            CodexSidecarBudget.maximumTimeoutSeconds
    )

    for field in ProtocolBudgetField.allCases {
        var values = ProtocolBudgetValues.maximum
        field.set(0, on: &values)
        expectSidecarError(.invalidBudgetField(field.wireName)) {
            _ = try values.makeBudget()
        }

        field.set(field.maximum, on: &values)
        _ = try values.makeBudget()

        field.set(field.maximum + 1, on: &values)
        expectSidecarError(.invalidBudgetField(field.wireName)) {
            _ = try values.makeBudget()
        }
    }
}

@Test("start fieldはmodel・application ID・prompt・schemaのv1境界を厳密に検査する")
func startFieldsUseExactProtocolConstraints() throws {
    let validModel = "A" + String(repeating: "-", count: 127)
    let validApplicationID = "a" + String(repeating: "-", count: 127)
    _ = try directStart(
        modelID: validModel,
        instructionID: validApplicationID,
        prompt: "x",
        schemaID: validApplicationID,
        schema: "{}"
    )

    for modelID in ["", " bad", "モデル", "A" + String(repeating: "-", count: 128)] {
        expectSidecarError(.invalidField("model_id")) {
            _ = try directStart(modelID: modelID)
        }
    }
    for applicationID in ["", "Uppercase", "a/path", "a" + String(repeating: "-", count: 128)] {
        expectSidecarError(.invalidField("application_instruction_id")) {
            _ = try directStart(instructionID: applicationID)
        }
        expectSidecarError(.invalidField("application_response_schema_id")) {
            _ = try directStart(schemaID: applicationID)
        }
    }
    for content in ["", " \n\t　", "\u{0085}", "\u{FEFF}"] {
        expectSidecarError(.invalidField("application_prompt")) {
            _ = try directStart(prompt: content)
        }
        expectSidecarError(.invalidField("application_response_schema")) {
            _ = try directStart(schema: content)
        }
    }
    _ = try directStart(prompt: "\u{200B}", schema: "\u{200B}")

    expectSidecarError(.invalidField("model_id")) {
        _ = try decodeStartFixture(replacing: "model_id", with: " default")
    }
    expectSidecarError(.invalidField("application_instruction_id")) {
        _ = try decodeStartFixture(replacing: "application_instruction_id", with: "Bad")
    }
    expectSidecarError(.invalidField("application_prompt")) {
        _ = try decodeStartFixture(replacing: "application_prompt", with: " \t")
    }
    expectSidecarError(.invalidField("application_response_schema_id")) {
        _ = try decodeStartFixture(replacing: "application_response_schema_id", with: "bad/path")
    }
    expectSidecarError(.invalidField("application_response_schema")) {
        _ = try decodeStartFixture(replacing: "application_response_schema", with: "\n")
    }
}
