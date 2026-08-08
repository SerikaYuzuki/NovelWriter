import CoreFoundation
import Foundation

enum CodexSidecarMessageCodec {
    private static let maximumSafeInteger: Int64 = 9_007_199_254_740_991
    static let startKeys: Set<String> = [
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
    private static let helloKeys: Set<String> = ["version", "type", "request_id"]
    private static let cancelKeys: Set<String> = ["version", "type", "request_id"]
    static let budgetKeys: Set<String> = [
        "maximum_input_characters",
        "maximum_input_utf8_bytes",
        "maximum_output_characters",
        "maximum_output_utf8_bytes",
        "maximum_output_tokens",
        "maximum_warnings",
        "timeout_seconds"
    ]
    private static let startedKeys: Set<String> = ["version", "type", "request_id"]
    static let readyKeys: Set<String> = ["version", "type", "request_id", "runtime"]
    static let runtimeKeys: Set<String> = [
        "mode",
        "sidecar_version",
        "sidecar_bundle_sha256",
        "node_version",
        "node_sha256",
        "architecture",
        "sdk_version",
        "sdk_integrity",
        "cli_version",
        "cli_sha256"
    ]
    static let completedKeys: Set<String> = [
        "version",
        "type",
        "request_id",
        "structured_output",
        "usage"
    ]
    static let failedKeys: Set<String> = ["version", "type", "request_id", "code"]
    static let usageKeys: Set<String> = ["input_tokens", "output_tokens"]

    static func decodeCommand(frame: String) throws -> CodexSidecarCommand {
        let object = try parseObject(frame)
        try validateVersion(object)
        switch try string(object["type"], field: "type") {
        case "hello":
            try validateExactKeys(object, expected: helloKeys)
            return try .hello(
                CodexSidecarHelloCommand(
                    requestID: requestID(object["request_id"])
                )
            )
        case "start":
            return try .start(decodeStart(object))
        case "cancel":
            try validateExactKeys(object, expected: cancelKeys)
            return try .cancel(
                CodexSidecarCancelCommand(
                    requestID: requestID(object["request_id"])
                )
            )
        default:
            throw CodexSidecarLocalError.unsupportedMessageType
        }
    }

    static func decodeEvent(frame: String) throws -> CodexSidecarEvent {
        let object = try parseObject(frame)
        try validateVersion(object)
        switch try string(object["type"], field: "type") {
        case "ready":
            return try decodeReady(object)
        case "started":
            try validateExactKeys(object, expected: startedKeys)
            return try .started(requestID: requestID(object["request_id"]))
        case "completed":
            return try decodeCompleted(object)
        case "failed":
            return try decodeFailed(object)
        default:
            throw CodexSidecarLocalError.unsupportedMessageType
        }
    }

    static func validateExactKeys(
        _ object: [String: Any],
        expected: Set<String>
    ) throws {
        guard Set(object.keys) == expected else {
            throw CodexSidecarLocalError.unexpectedFields
        }
    }

    static func requestID(_ value: Any?) throws -> CodexSidecarRequestID {
        try CodexSidecarRequestID(validating: string(value, field: "request_id"))
    }

    static func string(_ value: Any?, field: String) throws -> String {
        guard let value = value as? String else {
            throw CodexSidecarLocalError.invalidField(field)
        }
        return value
    }

    static func nestedObject(_ value: Any?, field: String) throws -> [String: Any] {
        guard let value = value as? [String: Any] else {
            throw CodexSidecarLocalError.invalidField(field)
        }
        return value
    }

    static func nullableString(_ value: Any?, field: String) throws -> String? {
        if value is NSNull {
            return nil
        }
        return try string(value, field: field)
    }

    static func integer(_ value: Any?, field: String) throws -> Int {
        guard let number = value as? NSNumber else {
            throw CodexSidecarLocalError.invalidField(field)
        }
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw CodexSidecarLocalError.invalidField(field)
        }
        let objectiveCType = String(cString: number.objCType)
        guard objectiveCType != "f", objectiveCType != "d" else {
            throw CodexSidecarLocalError.invalidField(field)
        }
        let int64 = number.int64Value
        guard int64 >= 0, int64 <= maximumSafeInteger else {
            throw CodexSidecarLocalError.invalidField(field)
        }
        guard NSNumber(value: int64).compare(number) == .orderedSame else {
            throw CodexSidecarLocalError.invalidField(field)
        }
        guard let integer = Int(exactly: int64) else {
            throw CodexSidecarLocalError.invalidField(field)
        }
        return integer
    }

    private static func parseObject(_ frame: String) throws -> [String: Any] {
        var scanner = CodexStrictJSONScanner(frame)
        do {
            try scanner.validate()
        } catch CodexStrictJSONScanner.ScanError.duplicateObjectMember {
            throw CodexSidecarLocalError.duplicateJSONMember
        } catch {
            throw CodexSidecarLocalError.malformedJSON
        }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: Data(frame.utf8))
        } catch {
            throw CodexSidecarLocalError.malformedJSON
        }
        guard let object = value as? [String: Any] else {
            throw CodexSidecarLocalError.topLevelObjectRequired
        }
        return object
    }

    private static func validateVersion(_ object: [String: Any]) throws {
        guard try integer(object["version"], field: "version") == 1 else {
            throw CodexSidecarLocalError.unsupportedVersion
        }
    }
}
