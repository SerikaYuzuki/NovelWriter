import Foundation
import NovelAI

enum CodexSidecarRuntimeMode: String, Sendable, Equatable {
    case mock
    case codexSDK = "codex_sdk"
}

enum CodexSidecarArchitecture: String, Sendable, Equatable {
    case arm64
    case x64
}

struct CodexSidecarRuntimeIdentity: Sendable, Equatable {
    private struct ArtifactIdentity {
        let sidecarBundleSHA256: String?
        let nodeSHA256: String?
        let sdkVersion: String?
        let sdkIntegrity: String?
        let cliVersion: String?
        let cliSHA256: String?

        var values: [String?] {
            [
                sidecarBundleSHA256,
                nodeSHA256,
                sdkVersion,
                sdkIntegrity,
                cliVersion,
                cliSHA256
            ]
        }
    }

    let mode: CodexSidecarRuntimeMode
    let sidecarVersion: String
    let sidecarBundleSHA256: String?
    let nodeVersion: String
    let nodeSHA256: String?
    let architecture: CodexSidecarArchitecture
    let sdkVersion: String?
    let sdkIntegrity: String?
    let cliVersion: String?
    let cliSHA256: String?

    init(
        mode: CodexSidecarRuntimeMode,
        sidecarVersion: String,
        sidecarBundleSHA256: String?,
        nodeVersion: String,
        nodeSHA256: String?,
        architecture: CodexSidecarArchitecture,
        sdkVersion: String?,
        sdkIntegrity: String?,
        cliVersion: String?,
        cliSHA256: String?
    ) throws {
        guard Self.isBoundedIdentity(sidecarVersion) else {
            throw CodexSidecarLocalError.invalidField("runtime")
        }
        guard Self.isBoundedIdentity(nodeVersion) else {
            throw CodexSidecarLocalError.invalidField("runtime")
        }

        let artifactIdentity = ArtifactIdentity(
            sidecarBundleSHA256: sidecarBundleSHA256,
            nodeSHA256: nodeSHA256,
            sdkVersion: sdkVersion,
            sdkIntegrity: sdkIntegrity,
            cliVersion: cliVersion,
            cliSHA256: cliSHA256
        )
        switch mode {
        case .mock:
            try Self.validateMockIdentity(artifactIdentity)
        case .codexSDK:
            try Self.validateCodexSDKIdentity(artifactIdentity)
        }

        self.mode = mode
        self.sidecarVersion = sidecarVersion
        self.sidecarBundleSHA256 = sidecarBundleSHA256
        self.nodeVersion = nodeVersion
        self.nodeSHA256 = nodeSHA256
        self.architecture = architecture
        self.sdkVersion = sdkVersion
        self.sdkIntegrity = sdkIntegrity
        self.cliVersion = cliVersion
        self.cliSHA256 = cliSHA256
    }

    private static func validateMockIdentity(_ identity: ArtifactIdentity) throws {
        guard identity.values.allSatisfy({ $0 == nil }) else {
            throw CodexSidecarLocalError.invalidField("runtime")
        }
    }

    private static func validateCodexSDKIdentity(_ identity: ArtifactIdentity) throws {
        let values = identity.values.compactMap(\.self)
        guard values.count == identity.values.count else { throw invalidRuntimeError() }
        let validations = [
            isSHA256(values[0]),
            isSHA256(values[1]),
            isBoundedIdentity(values[2]),
            isSHA512SRI(values[3]),
            isBoundedIdentity(values[4]),
            isSHA256(values[5])
        ]
        guard validations.allSatisfy(\.self) else { throw invalidRuntimeError() }
    }

    private static func invalidRuntimeError() -> CodexSidecarLocalError {
        .invalidField("runtime")
    }

    private static func isBoundedIdentity(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 &&
            value.unicodeScalars.allSatisfy { (0x21 ... 0x7E).contains($0.value) }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0)
        }
    }

    private static func isSHA512SRI(_ value: String) -> Bool {
        let prefix = "sha512-"
        guard value.hasPrefix(prefix) else { return false }
        let encoded = String(value.dropFirst(prefix.count))
        guard let decoded = Data(base64Encoded: encoded), decoded.count == 64 else {
            return false
        }
        return decoded.base64EncodedString() == encoded
    }
}

struct CodexSidecarUsage: Sendable, Equatable {
    private static let maximumSafeInteger = 9_007_199_254_740_991

    let inputTokens: Int?
    let outputTokens: Int

    init(inputTokens: Int?, outputTokens: Int) throws {
        guard inputTokens.map({ (0 ... Self.maximumSafeInteger).contains($0) }) ?? true else {
            throw CodexSidecarLocalError.invalidField("input_tokens")
        }
        guard (0 ... Self.maximumSafeInteger).contains(outputTokens) else {
            throw CodexSidecarLocalError.invalidField("output_tokens")
        }
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

enum CodexSidecarFailureCode: String, CaseIterable, Sendable, Equatable {
    case cancelled
    case timedOut = "timed_out"
    case authenticationRequired = "authentication_required"
    case offline
    case rateLimited = "rate_limited"
    case quotaExceeded = "quota_exceeded"
    case providerUnavailable = "provider_unavailable"
    case refused
    case invalidResponse = "invalid_response"
    case providerMismatch = "provider_mismatch"

    var aiError: AIError {
        switch self {
        case .cancelled: .cancelled
        case .timedOut: .timedOut
        case .authenticationRequired: .authenticationRequired
        case .offline: .offline
        case .rateLimited: .rateLimited
        case .quotaExceeded: .quotaExceeded
        case .providerUnavailable: .providerUnavailable
        case .refused: .refused
        case .invalidResponse: .invalidResponse
        case .providerMismatch: .providerMismatch
        }
    }
}

enum CodexSidecarEvent: Sendable, Equatable {
    case ready(
        requestID: CodexSidecarRequestID,
        runtime: CodexSidecarRuntimeIdentity
    )
    case started(requestID: CodexSidecarRequestID)
    case completed(
        requestID: CodexSidecarRequestID,
        structuredOutput: String,
        usage: CodexSidecarUsage
    )
    case failed(requestID: CodexSidecarRequestID, code: CodexSidecarFailureCode)

    var requestID: CodexSidecarRequestID {
        switch self {
        case let .ready(requestID, _),
             let .started(requestID),
             let .completed(requestID, _, _),
             let .failed(requestID, _):
            requestID
        }
    }

    var isTerminal: Bool {
        switch self {
        case .ready, .started: false
        case .completed, .failed: true
        }
    }
}
