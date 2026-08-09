import Foundation

extension CodexSidecarMessageCodec {
    static func encodeCommandFrame(_ command: CodexSidecarCommand) throws -> Data {
        switch command {
        case let .hello(hello):
            return try encodeFrame([
                "version": 1,
                "type": "hello",
                "request_id": hello.requestID.rawValue
            ])
        case let .start(start):
            _ = start
            throw CodexSidecarLocalError.startBeforeAttestation
        case let .cancel(cancel):
            return try encodeFrame([
                "version": 1,
                "type": "cancel",
                "request_id": cancel.requestID.rawValue
            ])
        }
    }

    static func encodeAttestedStartFrame(_ attested: CodexSidecarAttestedStart) throws -> Data {
        let start = attested.command
        return try encodeFrame([
            "version": 1,
            "type": "start",
            "request_id": start.requestID.rawValue,
            "provider_id": "codex",
            "model_id": start.modelID,
            "application_instruction_id": start.applicationInstructionID,
            "application_prompt": start.applicationPrompt,
            "application_response_schema_id": start.applicationResponseSchemaID,
            "application_response_schema": start.applicationResponseSchema,
            "budget": budgetObject(start.budget),
            "input_character_count": start.inputCharacterCount,
            "input_utf8_byte_count": start.inputUTF8ByteCount
        ])
    }

    static func encodeEventFrame(_ event: CodexSidecarEvent) throws -> Data {
        switch event {
        case let .ready(requestID, runtime):
            try encodeFrame([
                "version": 1,
                "type": "ready",
                "request_id": requestID.rawValue,
                "runtime": runtimeObject(runtime)
            ])
        case let .started(requestID):
            try encodeFrame([
                "version": 1,
                "type": "started",
                "request_id": requestID.rawValue
            ])
        case let .completed(requestID, structuredOutput, usage):
            try encodeFrame([
                "version": 1,
                "type": "completed",
                "request_id": requestID.rawValue,
                "structured_output": structuredOutput,
                "usage": [
                    "input_tokens": nullableJSONValue(usage.inputTokens),
                    "output_tokens": usage.outputTokens
                ]
            ])
        case let .failed(requestID, code):
            try encodeFrame([
                "version": 1,
                "type": "failed",
                "request_id": requestID.rawValue,
                "code": code.rawValue
            ])
        }
    }

    private static func budgetObject(_ budget: CodexSidecarBudget) -> [String: Any] {
        [
            "maximum_input_characters": budget.maximumInputCharacters,
            "maximum_input_utf8_bytes": budget.maximumInputUTF8Bytes,
            "maximum_output_characters": budget.maximumOutputCharacters,
            "maximum_output_utf8_bytes": budget.maximumOutputUTF8Bytes,
            "maximum_output_tokens": budget.maximumOutputTokens,
            "maximum_warnings": budget.maximumWarnings,
            "timeout_seconds": budget.timeoutSeconds
        ]
    }

    private static func runtimeObject(_ runtime: CodexSidecarRuntimeIdentity) -> [String: Any] {
        [
            "mode": runtime.mode.rawValue,
            "sidecar_version": runtime.sidecarVersion,
            "sidecar_bundle_sha256": nullableJSONValue(runtime.sidecarBundleSHA256),
            "node_version": runtime.nodeVersion,
            "node_sha256": nullableJSONValue(runtime.nodeSHA256),
            "architecture": runtime.architecture.rawValue,
            "sdk_version": nullableJSONValue(runtime.sdkVersion),
            "sdk_integrity": nullableJSONValue(runtime.sdkIntegrity),
            "cli_version": nullableJSONValue(runtime.cliVersion),
            "cli_sha256": nullableJSONValue(runtime.cliSHA256)
        ]
    }

    private static func nullableJSONValue(_ value: (some Any)?) -> Any {
        if let value {
            return value
        }
        return NSNull()
    }

    private static func encodeFrame(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CodexSidecarLocalError.serializationFailed
        }
        let payload: Data
        do {
            payload = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw CodexSidecarLocalError.serializationFailed
        }
        guard payload.count <= CodexSidecarFrameDecoder.maximumFrameBytes else {
            throw CodexSidecarLocalError.frameTooLarge(
                limit: CodexSidecarFrameDecoder.maximumFrameBytes,
                actual: payload.count
            )
        }
        var frame = payload
        frame.append(0x0A)
        return frame
    }
}
