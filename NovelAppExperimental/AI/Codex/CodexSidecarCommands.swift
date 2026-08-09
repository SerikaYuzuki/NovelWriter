import Foundation
import NovelAI

struct CodexSidecarStartCommand: Sendable, Equatable {
    let requestID: CodexSidecarRequestID
    let modelID: String
    let applicationInstructionID: String
    let applicationPrompt: String
    let applicationResponseSchemaID: String
    let applicationResponseSchema: String
    let budget: CodexSidecarBudget
    let inputCharacterCount: Int
    let inputUTF8ByteCount: Int

    init(
        requestID: CodexSidecarRequestID,
        applicationPayload payload: AIApplicationPayload
    ) throws {
        guard payload.provider.id == .codex else {
            throw CodexSidecarLocalError.providerMismatch
        }
        let expectedCharacterCount = try Self.sum(
            payload.applicationPrompt.count,
            payload.applicationResponseSchema.count
        )
        guard payload.inputCharacterCount == expectedCharacterCount else {
            throw CodexSidecarLocalError.inputCountMismatch
        }
        try self.init(
            requestID: requestID,
            modelID: payload.provider.modelID,
            applicationInstructionID: payload.applicationInstructionID,
            applicationPrompt: payload.applicationPrompt,
            applicationResponseSchemaID: payload.applicationResponseSchemaID,
            applicationResponseSchema: payload.applicationResponseSchema,
            budget: CodexSidecarBudget(payload.budget),
            inputCharacterCount: payload.inputCharacterCount,
            inputUTF8ByteCount: payload.inputUTF8ByteCount
        )
    }

    init(
        requestID: CodexSidecarRequestID,
        modelID: String,
        applicationInstructionID: String,
        applicationPrompt: String,
        applicationResponseSchemaID: String,
        applicationResponseSchema: String,
        budget: CodexSidecarBudget,
        inputCharacterCount: Int,
        inputUTF8ByteCount: Int
    ) throws {
        guard Self.isValidModelID(modelID) else {
            throw CodexSidecarLocalError.invalidField("model_id")
        }
        guard Self.isValidApplicationID(applicationInstructionID) else {
            throw CodexSidecarLocalError.invalidField("application_instruction_id")
        }
        guard Self.containsNonWhitespace(applicationPrompt) else {
            throw CodexSidecarLocalError.invalidField("application_prompt")
        }
        guard Self.isValidApplicationID(applicationResponseSchemaID) else {
            throw CodexSidecarLocalError.invalidField("application_response_schema_id")
        }
        guard Self.containsNonWhitespace(applicationResponseSchema) else {
            throw CodexSidecarLocalError.invalidField("application_response_schema")
        }
        let expectedUTF8ByteCount = try Self.sum(
            applicationPrompt.utf8.count,
            applicationResponseSchema.utf8.count
        )
        guard inputCharacterCount >= 0 else {
            throw CodexSidecarLocalError.inputCountMismatch
        }
        guard inputUTF8ByteCount == expectedUTF8ByteCount else {
            throw CodexSidecarLocalError.inputCountMismatch
        }
        guard inputCharacterCount <= budget.maximumInputCharacters else {
            throw CodexSidecarLocalError.inputCountMismatch
        }
        guard inputUTF8ByteCount <= budget.maximumInputUTF8Bytes else {
            throw CodexSidecarLocalError.inputCountMismatch
        }

        self.requestID = requestID
        self.modelID = modelID
        self.applicationInstructionID = applicationInstructionID
        self.applicationPrompt = applicationPrompt
        self.applicationResponseSchemaID = applicationResponseSchemaID
        self.applicationResponseSchema = applicationResponseSchema
        self.budget = budget
        self.inputCharacterCount = inputCharacterCount
        self.inputUTF8ByteCount = inputUTF8ByteCount
    }

    private static func isValidModelID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1 ... 128).contains(bytes.count) else { return false }
        guard let first = bytes.first else { return false }
        guard isASCIILetterOrDigit(first) else { return false }
        return bytes.dropFirst().allSatisfy {
            isASCIILetterOrDigit($0) || [0x2E, 0x5F, 0x3A, 0x2F, 0x2D].contains($0)
        }
    }

    private static func isValidApplicationID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1 ... 128).contains(bytes.count) else { return false }
        guard let first = bytes.first else { return false }
        guard isASCIILowercaseLetterOrDigit(first) else { return false }
        return bytes.dropFirst().allSatisfy {
            isASCIILowercaseLetterOrDigit($0) || [0x2E, 0x5F, 0x2D].contains($0)
        }
    }

    private static func isASCIILetterOrDigit(_ byte: UInt8) -> Bool {
        isASCIILowercaseLetterOrDigit(byte) || (0x41 ... 0x5A).contains(byte)
    }

    private static func isASCIILowercaseLetterOrDigit(_ byte: UInt8) -> Bool {
        (0x61 ... 0x7A).contains(byte) || (0x30 ... 0x39).contains(byte)
    }

    private static func containsNonWhitespace(_ value: String) -> Bool {
        value.unicodeScalars.contains { !isProtocolWhitespace($0.value) }
    }

    private static func isProtocolWhitespace(_ value: UInt32) -> Bool {
        (0x0009 ... 0x000D).contains(value) ||
            value == 0x0020 || value == 0x0085 || value == 0x00A0 ||
            value == 0x1680 || (0x2000 ... 0x200A).contains(value) ||
            value == 0x2028 || value == 0x2029 || value == 0x202F ||
            value == 0x205F || value == 0x3000 || value == 0xFEFF
    }

    private static func sum(_ lhs: Int, _ rhs: Int) throws -> Int {
        let sum = lhs.addingReportingOverflow(rhs)
        guard !sum.overflow else {
            throw CodexSidecarLocalError.inputCountMismatch
        }
        return sum.partialValue
    }
}

struct CodexSidecarCancelCommand: Sendable, Equatable {
    let requestID: CodexSidecarRequestID
}

struct CodexSidecarHelloCommand: Sendable, Equatable {
    let requestID: CodexSidecarRequestID
}

enum CodexSidecarCommand: Sendable, Equatable {
    case hello(CodexSidecarHelloCommand)
    case start(CodexSidecarStartCommand)
    case cancel(CodexSidecarCancelCommand)
}
