import Foundation

/// Provider adapterへ渡す、明示確認対象の全application contentと実行条件。
///
/// `applicationPrompt`と`applicationResponseSchema`はdomainが生成し、adapterは再構築・追記しない。
/// public initializerを持たず、validation済みpreviewからだけ封印される。
public struct AIApplicationPayload: Sendable, Equatable {
    public let provider: AIProviderDescriptor
    public let purpose: AIRequestPurpose
    public let applicationInstructionID: String
    public let applicationPrompt: String
    public let applicationResponseSchemaID: String
    public let applicationResponseSchema: String
    public let budget: AIRequestBudget
    public let inputCharacterCount: Int
    public let inputUTF8ByteCount: Int
}

private final class AIRequestExecutionLease: @unchecked Sendable {
    private let lock = NSLock()
    private var isClaimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isClaimed else { return false }
        isClaimed = true
        return true
    }
}

/// provider/model、固定instruction、選択文字列、response schema、budgetを含むpreview。
///
/// これはwire headerのpreviewではなく、アプリがprovider adapterへ供給する全application contentの
/// exact snapshotである。Adapterは未表示の文脈・metadata・instructionを追加してはならない。
/// public initializerを持たず、validation済みdraftからだけ生成される。
public struct AIOutboundPreview: Sendable {
    public let provider: AIProviderDescriptor
    public let purpose: AIRequestPurpose
    public let applicationInstructionID: String
    public let applicationInstruction: String
    public let applicationResponseSchemaID: String
    public let applicationResponseSchema: String
    public let selectedText: AISelectedText
    public let budget: AIRequestBudget
    public let selectedTextCharacterCount: Int
    public let selectedTextUTF8ByteCount: Int
    public let applicationPayload: AIApplicationPayload
    private let executionLease = AIRequestExecutionLease()

    public var applicationPrompt: String {
        applicationPayload.applicationPrompt
    }

    public var inputCharacterCount: Int {
        applicationPayload.inputCharacterCount
    }

    public var inputUTF8ByteCount: Int {
        applicationPayload.inputUTF8ByteCount
    }

    /// UIでの明示確認後にだけ呼ぶ。Providerが受け取れるsealed型はここで初めて生成される。
    public func confirmForSending() -> AIConfirmedRequest {
        AIConfirmedRequest(
            outbound: applicationPayload,
            executionLease: executionLease
        )
    }
}

/// 明示確認済みのprovider実行request。内容はpreviewから封印したapplication payloadだけである。
public struct AIConfirmedRequest: Sendable {
    public let outbound: AIApplicationPayload
    private let executionLease: AIRequestExecutionLease

    fileprivate init(
        outbound: AIApplicationPayload,
        executionLease: AIRequestExecutionLease
    ) {
        self.outbound = outbound
        self.executionLease = executionLease
    }

    func claimExecution() -> Bool {
        executionLease.claim()
    }

    /// Provider resultがrequestのoutput budget内かを検証する。
    public func validating(_ result: AIResult) throws -> AIResult {
        let actual = result.outputCharacterCount
        guard actual <= outbound.budget.maximumOutputCharacters else {
            throw AIError.outputCharacterLimitExceeded(
                limit: outbound.budget.maximumOutputCharacters,
                actual: actual
            )
        }
        let outputByteCount = result.outputUTF8ByteCount
        guard outputByteCount <= outbound.budget.maximumOutputUTF8Bytes else {
            throw AIError.outputUTF8ByteLimitExceeded(
                limit: outbound.budget.maximumOutputUTF8Bytes,
                actual: outputByteCount
            )
        }
        if let inputTokens = result.usage.inputTokens, inputTokens < 0 {
            throw AIError.invalidResponse
        }
        guard let outputTokens = result.usage.outputTokens, outputTokens >= 0 else {
            throw AIError.invalidResponse
        }
        guard outputTokens <= outbound.budget.maximumOutputTokens else {
            throw AIError.outputTokenLimitExceeded(
                limit: outbound.budget.maximumOutputTokens,
                actual: outputTokens
            )
        }
        return result
    }

    /// exact response schemaに適合するJSONだけを`AIResult`へ変換する。
    public func decodeResult(from structuredOutput: String, usage: AIUsage) throws -> AIResult {
        let rawCharacterCount = structuredOutput.count
        guard rawCharacterCount <= outbound.budget.maximumOutputCharacters else {
            throw AIError.outputCharacterLimitExceeded(
                limit: outbound.budget.maximumOutputCharacters,
                actual: rawCharacterCount
            )
        }
        let rawByteCount = structuredOutput.utf8.count
        guard rawByteCount <= outbound.budget.maximumOutputUTF8Bytes else {
            throw AIError.outputUTF8ByteLimitExceeded(
                limit: outbound.budget.maximumOutputUTF8Bytes,
                actual: rawByteCount
            )
        }
        do {
            let value = try JSONSerialization.jsonObject(with: Data(structuredOutput.utf8))
            guard let object = value as? [String: Any] else {
                throw AIError.invalidResponse
            }
            guard Set(object.keys) == ["replacement", "summary", "warnings"] else {
                throw AIError.invalidResponse
            }
            guard let replacement = object["replacement"] as? String else {
                throw AIError.invalidResponse
            }
            guard let summary = object["summary"] as? String else {
                throw AIError.invalidResponse
            }
            guard let warningValues = object["warnings"] as? [Any] else {
                throw AIError.invalidResponse
            }
            guard warningValues.allSatisfy({ $0 is String }) else {
                throw AIError.invalidResponse
            }
            let result = AIResult(
                replacement: replacement,
                summary: summary,
                warnings: warningValues.compactMap { $0 as? String },
                usage: usage
            )
            return try validating(result)
        } catch let error as AIError {
            throw error
        } catch {
            throw AIError.invalidResponse
        }
    }
}
