import Foundation
import NovelAI

enum CodexSidecarLocalError: Error, Sendable, Equatable {
    case decoderUnavailable
    case frameTooLarge(limit: Int, actual: Int)
    case streamByteLimitExceeded(limit: Int, actual: Int)
    case emptyFrame
    case carriageReturnNotAllowed
    case byteOrderMarkNotAllowed
    case invalidUTF8
    case unterminatedFrame
    case malformedJSON
    case duplicateJSONMember
    case topLevelObjectRequired
    case unsupportedVersion
    case unsupportedMessageType
    case unexpectedFields
    case invalidField(String)
    case invalidRequestID
    case providerMismatch
    case invalidBudgetField(String)
    case inputCountMismatch
    case serializationFailed
    case helloAlreadySent
    case startBeforeAttestation
    case runtimeIdentityMismatch
    case unexpectedReady
    case startAlreadySent
    case cancelBeforeStart
    case duplicateCancel
    case cancelAfterTerminal
    case eventBeforeStart
    case wrongRequestID
    case duplicateStarted
    case completedBeforeStarted
    case failedBeforeStarted
    case duplicateTerminal
    case eventAfterTerminal
    case unexpectedEOF
    case sessionUnavailable
}

struct CodexSidecarRequestID: Sendable, Hashable {
    let rawValue: String

    init(_ uuid: UUID) {
        rawValue = uuid.uuidString.lowercased()
    }

    init(validating rawValue: String) throws {
        guard let uuid = UUID(uuidString: rawValue) else {
            throw CodexSidecarLocalError.invalidRequestID
        }
        guard uuid.uuidString.lowercased() == rawValue else {
            throw CodexSidecarLocalError.invalidRequestID
        }
        self.rawValue = rawValue
    }
}

struct CodexSidecarBudget: Sendable, Equatable {
    static let maximumInputCharacters = 20000
    static let maximumInputUTF8Bytes = 80000
    static let maximumOutputCharacters = 20000
    static let maximumOutputUTF8Bytes = 80000
    static let maximumOutputTokens = 8192
    static let maximumWarnings = 20
    static let maximumTimeoutSeconds = 120

    let maximumInputCharacters: Int
    let maximumInputUTF8Bytes: Int
    let maximumOutputCharacters: Int
    let maximumOutputUTF8Bytes: Int
    let maximumOutputTokens: Int
    let maximumWarnings: Int
    let timeoutSeconds: Int

    init(_ budget: AIRequestBudget) throws {
        try Self.validate(
            value: budget.maximumInputCharacters,
            maximum: Self.maximumInputCharacters,
            field: "maximum_input_characters"
        )
        try Self.validate(
            value: budget.maximumInputUTF8Bytes,
            maximum: Self.maximumInputUTF8Bytes,
            field: "maximum_input_utf8_bytes"
        )
        try Self.validate(
            value: budget.maximumOutputCharacters,
            maximum: Self.maximumOutputCharacters,
            field: "maximum_output_characters"
        )
        try Self.validate(
            value: budget.maximumOutputUTF8Bytes,
            maximum: Self.maximumOutputUTF8Bytes,
            field: "maximum_output_utf8_bytes"
        )
        try Self.validate(
            value: budget.maximumOutputTokens,
            maximum: Self.maximumOutputTokens,
            field: "maximum_output_tokens"
        )
        try Self.validate(
            value: budget.maximumWarnings,
            maximum: Self.maximumWarnings,
            field: "maximum_warnings"
        )
        try Self.validate(
            value: budget.timeoutSeconds,
            maximum: Self.maximumTimeoutSeconds,
            field: "timeout_seconds"
        )
        maximumInputCharacters = budget.maximumInputCharacters
        maximumInputUTF8Bytes = budget.maximumInputUTF8Bytes
        maximumOutputCharacters = budget.maximumOutputCharacters
        maximumOutputUTF8Bytes = budget.maximumOutputUTF8Bytes
        maximumOutputTokens = budget.maximumOutputTokens
        maximumWarnings = budget.maximumWarnings
        timeoutSeconds = budget.timeoutSeconds
    }

    init(
        maximumInputCharacters: Int,
        maximumInputUTF8Bytes: Int,
        maximumOutputCharacters: Int,
        maximumOutputUTF8Bytes: Int,
        maximumOutputTokens: Int,
        maximumWarnings: Int,
        timeoutSeconds: Int
    ) throws {
        let budget = AIRequestBudget(
            maximumInputCharacters: maximumInputCharacters,
            maximumInputUTF8Bytes: maximumInputUTF8Bytes,
            maximumOutputCharacters: maximumOutputCharacters,
            maximumOutputUTF8Bytes: maximumOutputUTF8Bytes,
            maximumOutputTokens: maximumOutputTokens,
            maximumWarnings: maximumWarnings,
            timeoutSeconds: timeoutSeconds
        )
        try self.init(budget)
    }

    private static func validate(value: Int, maximum: Int, field: String) throws {
        guard value > 0, value <= maximum else {
            throw CodexSidecarLocalError.invalidBudgetField(field)
        }
    }
}
