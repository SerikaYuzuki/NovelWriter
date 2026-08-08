import Foundation

extension CodexSidecarMessageCodec {
    static func decodeReady(_ object: [String: Any]) throws -> CodexSidecarEvent {
        try validateExactKeys(object, expected: readyKeys)
        return try .ready(
            requestID: requestID(object["request_id"]),
            runtime: decodeRuntime(object["runtime"])
        )
    }

    static func decodeStart(_ object: [String: Any]) throws -> CodexSidecarStartCommand {
        try validateExactKeys(object, expected: startKeys)
        guard try string(object["provider_id"], field: "provider_id") == "codex" else {
            throw CodexSidecarLocalError.providerMismatch
        }
        return try CodexSidecarStartCommand(
            requestID: requestID(object["request_id"]),
            modelID: string(object["model_id"], field: "model_id"),
            applicationInstructionID: string(
                object["application_instruction_id"],
                field: "application_instruction_id"
            ),
            applicationPrompt: string(
                object["application_prompt"],
                field: "application_prompt"
            ),
            applicationResponseSchemaID: string(
                object["application_response_schema_id"],
                field: "application_response_schema_id"
            ),
            applicationResponseSchema: string(
                object["application_response_schema"],
                field: "application_response_schema"
            ),
            budget: decodeBudget(object["budget"]),
            inputCharacterCount: integer(
                object["input_character_count"],
                field: "input_character_count"
            ),
            inputUTF8ByteCount: integer(
                object["input_utf8_byte_count"],
                field: "input_utf8_byte_count"
            )
        )
    }

    static func decodeCompleted(_ object: [String: Any]) throws -> CodexSidecarEvent {
        try validateExactKeys(object, expected: completedKeys)
        let usageObject = try nestedObject(object["usage"], field: "usage")
        try validateExactKeys(usageObject, expected: usageKeys)
        let inputTokens: Int? = if usageObject["input_tokens"] is NSNull {
            nil
        } else {
            try integer(usageObject["input_tokens"], field: "input_tokens")
        }
        let usage = try CodexSidecarUsage(
            inputTokens: inputTokens,
            outputTokens: integer(usageObject["output_tokens"], field: "output_tokens")
        )
        return try .completed(
            requestID: requestID(object["request_id"]),
            structuredOutput: string(object["structured_output"], field: "structured_output"),
            usage: usage
        )
    }

    static func decodeFailed(_ object: [String: Any]) throws -> CodexSidecarEvent {
        try validateExactKeys(object, expected: failedKeys)
        let rawCode = try string(object["code"], field: "code")
        guard let code = CodexSidecarFailureCode(rawValue: rawCode) else {
            throw CodexSidecarLocalError.invalidField("code")
        }
        return try .failed(
            requestID: requestID(object["request_id"]),
            code: code
        )
    }

    private static func decodeRuntime(_ value: Any?) throws -> CodexSidecarRuntimeIdentity {
        let object = try nestedObject(value, field: "runtime")
        try validateExactKeys(object, expected: runtimeKeys)
        let rawMode = try string(object["mode"], field: "mode")
        guard let mode = CodexSidecarRuntimeMode(rawValue: rawMode) else {
            throw CodexSidecarLocalError.invalidField("mode")
        }
        let rawArchitecture = try string(object["architecture"], field: "architecture")
        guard let architecture = CodexSidecarArchitecture(rawValue: rawArchitecture) else {
            throw CodexSidecarLocalError.invalidField("architecture")
        }
        return try CodexSidecarRuntimeIdentity(
            mode: mode,
            sidecarVersion: string(object["sidecar_version"], field: "sidecar_version"),
            sidecarBundleSHA256: nullableString(
                object["sidecar_bundle_sha256"],
                field: "sidecar_bundle_sha256"
            ),
            nodeVersion: string(object["node_version"], field: "node_version"),
            nodeSHA256: nullableString(object["node_sha256"], field: "node_sha256"),
            architecture: architecture,
            sdkVersion: nullableString(object["sdk_version"], field: "sdk_version"),
            sdkIntegrity: nullableString(object["sdk_integrity"], field: "sdk_integrity"),
            cliVersion: nullableString(object["cli_version"], field: "cli_version"),
            cliSHA256: nullableString(object["cli_sha256"], field: "cli_sha256")
        )
    }

    private static func decodeBudget(_ value: Any?) throws -> CodexSidecarBudget {
        let object = try nestedObject(value, field: "budget")
        try validateExactKeys(object, expected: budgetKeys)
        return try CodexSidecarBudget(
            maximumInputCharacters: integer(
                object["maximum_input_characters"],
                field: "maximum_input_characters"
            ),
            maximumInputUTF8Bytes: integer(
                object["maximum_input_utf8_bytes"],
                field: "maximum_input_utf8_bytes"
            ),
            maximumOutputCharacters: integer(
                object["maximum_output_characters"],
                field: "maximum_output_characters"
            ),
            maximumOutputUTF8Bytes: integer(
                object["maximum_output_utf8_bytes"],
                field: "maximum_output_utf8_bytes"
            ),
            maximumOutputTokens: integer(
                object["maximum_output_tokens"],
                field: "maximum_output_tokens"
            ),
            maximumWarnings: integer(
                object["maximum_warnings"],
                field: "maximum_warnings"
            ),
            timeoutSeconds: integer(
                object["timeout_seconds"],
                field: "timeout_seconds"
            )
        )
    }
}
