import Foundation
@testable import FUMINIWAExperimental
import Testing

@Test("LF frame decoderはUTF-8 code unitと複数frameのchunk分割を保持する")
func frameDecoderPreservesArbitraryChunkSplits() throws {
    let first = Data(#"{"value":"猫😀"}"#.utf8) + Data([0x0A])
    let second = Data(#"{"value":"e\u0301"}"#.utf8) + Data([0x0A])
    let input = first + second
    var decoder = CodexSidecarFrameDecoder()
    var frames: [String] = []

    for byte in input {
        try frames.append(contentsOf: decoder.append(Data([byte])))
    }
    try decoder.finish()

    #expect(frames == [#"{"value":"猫😀"}"#, #"{"value":"e\u0301"}"#])
}

@Test("LF frame decoderは上限ちょうどを受理し1 byte超過を即時拒否する")
func frameDecoderEnforcesByteLimitWithoutWaitingForLF() throws {
    var exactDecoder = CodexSidecarFrameDecoder()
    let exact = Data(repeating: 0x61, count: CodexSidecarFrameDecoder.maximumFrameBytes) +
        Data([0x0A])
    let exactFrames = try exactDecoder.append(exact)
    #expect(exactFrames.count == 1)
    #expect(exactFrames.first?.utf8.count == CodexSidecarFrameDecoder.maximumFrameBytes)
    try exactDecoder.finish()

    var oversizedDecoder = CodexSidecarFrameDecoder()
    expectSidecarError(
        .frameTooLarge(
            limit: CodexSidecarFrameDecoder.maximumFrameBytes,
            actual: CodexSidecarFrameDecoder.maximumFrameBytes + 1
        )
    ) {
        _ = try oversizedDecoder.append(
            Data(repeating: 0x61, count: CodexSidecarFrameDecoder.maximumFrameBytes + 1)
        )
    }
    expectSidecarError(.decoderUnavailable) {
        _ = try oversizedDecoder.append(Data([0x0A]))
    }
}

@Test("LF frame decoderはinvalid UTF-8・CRLF・BOM・empty・partial EOFを拒否する")
func frameDecoderRejectsInvalidWireForms() {
    var invalidUTF8 = CodexSidecarFrameDecoder()
    expectSidecarError(.invalidUTF8) {
        _ = try invalidUTF8.append(Data([0x7B, 0xFF, 0x7D, 0x0A]))
    }

    var carriageReturn = CodexSidecarFrameDecoder()
    expectSidecarError(.carriageReturnNotAllowed) {
        _ = try carriageReturn.append(Data("{}\r\n".utf8))
    }

    var byteOrderMark = CodexSidecarFrameDecoder()
    expectSidecarError(.byteOrderMarkNotAllowed) {
        _ = try byteOrderMark.append(Data([0xEF, 0xBB, 0xBF]) + Data("{}\n".utf8))
    }

    var empty = CodexSidecarFrameDecoder()
    expectSidecarError(.emptyFrame) {
        _ = try empty.append(Data([0x0A]))
    }

    var partial = CodexSidecarFrameDecoder()
    expectSidecarError(.unterminatedFrame) {
        _ = try partial.append(Data("{}".utf8))
        try partial.finish()
    }
}

@Test("LF frame decoderは正常EOF後のappendとsecond finishを拒否する")
func frameDecoderClosesAfterSuccessfulFinish() throws {
    var decoder = CodexSidecarFrameDecoder()
    #expect(try decoder.append(Data("{}\n".utf8)) == ["{}"])
    try decoder.finish()

    expectSidecarError(.decoderUnavailable) {
        _ = try decoder.append(Data("{}\n".utf8))
    }
    expectSidecarError(.decoderUnavailable) {
        try decoder.finish()
    }
}

@Test("codecはunknown・malformed・余分なfield・duplicate memberを拒否する")
func codecRejectsUnknownAndMalformedMessages() {
    expectSidecarError(.unsupportedMessageType) {
        _ = try CodexSidecarMessageCodec.decodeEvent(
            frame: #"{"version":1,"type":"mystery"}"#
        )
    }
    expectSidecarError(.malformedJSON) {
        _ = try CodexSidecarMessageCodec.decodeEvent(frame: "{")
    }
    expectSidecarError(.unexpectedFields) {
        _ = try CodexSidecarMessageCodec.decodeEvent(
            frame: startedEventFrame(extraMembers: #", "extra":true"#)
        )
    }
    expectSidecarError(.duplicateJSONMember) {
        _ = try CodexSidecarMessageCodec.decodeEvent(
            frame: startedEventFrame(
                extraMembers: #", "request_\u0069d":"00000000-0000-0000-0000-000000000001""#
            )
        )
    }
}

@Test("codecはcanonical UUID・safe integer・exact enumを要求する")
func codecRejectsInvalidIdentifiersNumbersAndEnums() {
    expectSidecarError(.invalidRequestID) {
        _ = try CodexSidecarMessageCodec.decodeEvent(
            frame: startedEventFrame(
                requestID: "00000000-0000-0000-0000-00000000000A"
            )
        )
    }
    expectSidecarError(.invalidField("version")) {
        _ = try CodexSidecarMessageCodec.decodeEvent(
            frame: startedEventFrame(version: "1.0")
        )
    }
    expectSidecarError(.invalidField("output_tokens")) {
        _ = try CodexSidecarMessageCodec.decodeEvent(
            frame: completedEventFrame(outputTokens: "9007199254740992")
        )
    }
    expectSidecarError(.invalidField("code")) {
        _ = try CodexSidecarMessageCodec.decodeEvent(
            frame: failedEventFrame(code: "raw_sdk_error")
        )
    }
    expectSidecarError(.malformedJSON) {
        _ = try CodexSidecarMessageCodec.decodeEvent(
            frame: startedEventFrame(version: "-0")
        )
    }
    expectSidecarError(.malformedJSON) {
        _ = try CodexSidecarMessageCodec.decodeEvent(
            frame: startedEventFrame(version: "01")
        )
    }
    expectSidecarError(.invalidField("output_tokens")) {
        _ = try CodexSidecarMessageCodec.decodeEvent(
            frame: completedEventFrame(outputTokens: "-1")
        )
    }
}

@Test("strict JSON scannerはunpaired surrogateを拒否しvalid pairを保持する")
func strictJSONScannerValidatesSurrogatePairs() throws {
    expectSidecarError(.malformedJSON) {
        _ = try CodexSidecarMessageCodec.decodeEvent(
            frame: #"{"version":1,"type":"started","request_\uD800id":""# +
                protocolRequestIDText + #""}"#
        )
    }
    expectSidecarError(.malformedJSON) {
        _ = try CodexSidecarMessageCodec.decodeEvent(
            frame: completedEventFrame(structuredOutput: #"\uD800"#)
        )
    }

    let event = try CodexSidecarMessageCodec.decodeEvent(
        frame: completedEventFrame(structuredOutput: #"\uD83D\uDE00"#)
    )
    guard case let .completed(_, structuredOutput, _) = event else {
        Issue.record("Expected completed event")
        return
    }
    #expect(structuredOutput == "😀")
}

@Test("strict JSON scannerはobject/arrayのcontainer深さ64だけを受理する")
func strictJSONScannerValidatesContainerDepth() throws {
    var depth64 = CodexStrictJSONScanner(nestedJSONObject(depth: 64))
    try depth64.validate()
    var depth65 = CodexStrictJSONScanner(nestedJSONObject(depth: 65))
    expectMalformedJSONScanner(&depth65)

    var emptyObjectDepth64 = CodexStrictJSONScanner(nestedEmptyJSONContainer(
        opening: "{\"value\":",
        closing: "}",
        depth: 64,
        emptyValue: "{}"
    ))
    try emptyObjectDepth64.validate()
    var emptyObjectDepth65 = CodexStrictJSONScanner(nestedEmptyJSONContainer(
        opening: "{\"value\":",
        closing: "}",
        depth: 65,
        emptyValue: "{}"
    ))
    expectMalformedJSONScanner(&emptyObjectDepth65)

    var emptyArrayDepth64 = CodexStrictJSONScanner(nestedEmptyJSONContainer(
        opening: "[",
        closing: "]",
        depth: 64,
        emptyValue: "[]"
    ))
    try emptyArrayDepth64.validate()
    var emptyArrayDepth65 = CodexStrictJSONScanner(nestedEmptyJSONContainer(
        opening: "[",
        closing: "]",
        depth: 65,
        emptyValue: "[]"
    ))
    expectMalformedJSONScanner(&emptyArrayDepth65)
}

@Test("runtime identityはlowercase SHA-256とcanonical sha512 SRIを要求する")
func runtimeIdentityValidatesHashesAndSRI() throws {
    let hash = String(repeating: "a", count: 64)
    let sri = "sha512-" + Data(repeating: 0x2A, count: 64).base64EncodedString()
    _ = try sdkRuntimeIdentity(nodeSHA256: hash, sdkIntegrity: sri)

    expectSidecarError(.invalidField("runtime")) {
        _ = try sdkRuntimeIdentity(
            nodeSHA256: String(repeating: "A", count: 64),
            sdkIntegrity: sri
        )
    }
    expectSidecarError(.invalidField("runtime")) {
        _ = try sdkRuntimeIdentity(nodeSHA256: hash, sdkIntegrity: "sha512-not-base64")
    }
    expectSidecarError(.invalidField("runtime")) {
        _ = try CodexSidecarRuntimeIdentity(
            mode: .mock,
            sidecarVersion: "protocol-v1-test",
            sidecarBundleSHA256: hash,
            nodeVersion: "0.0.0-test",
            nodeSHA256: nil,
            architecture: .arm64,
            sdkVersion: nil,
            sdkIntegrity: nil,
            cliVersion: nil,
            cliSHA256: nil
        )
    }
}

@Test("stdout decoderはper-process 524288 byte累計上限を強制する")
func frameDecoderEnforcesTotalStreamLimit() throws {
    let frame = Data(
        repeating: 0x61,
        count: CodexSidecarFrameDecoder.maximumStreamBytes / 2 - 1
    ) + Data([0x0A])
    var decoder = CodexSidecarFrameDecoder()
    #expect(try decoder.append(frame).count == 1)
    #expect(try decoder.append(frame).count == 1)
    expectSidecarError(
        .streamByteLimitExceeded(
            limit: CodexSidecarFrameDecoder.maximumStreamBytes,
            actual: CodexSidecarFrameDecoder.maximumStreamBytes + 1
        )
    ) {
        _ = try decoder.append(Data([0x61]))
    }
}
