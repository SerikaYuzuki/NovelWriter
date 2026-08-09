import Darwin
import Foundation

#if !FUMINIWA_ENABLE_EXPERIMENTAL_AI
#error("Codex Node executable inspection must only compile in FUMINIWAExperimental")
#endif

enum CodexNodeExecutableInspectionError: String, Error, Sendable, Equatable {
    case invalidPath = "invalid_path"
    case symbolicLink = "symbolic_link"
    case notRegularFile = "not_regular_file"
    case hardLink = "hard_link"
    case invalidOwner = "invalid_owner"
    case invalidMode = "invalid_mode"
    case notExecutable = "not_executable"
    case resourceLimit = "resource_limit"
    case fileChanged = "file_changed"
    case readFailed = "read_failed"
    case invalidMachO = "invalid_mach_o"
    case unsupportedArchitecture = "unsupported_architecture"
    case architectureMismatch = "architecture_mismatch"
}

enum CodexNodeMachOContainer: UInt8, Sendable, Equatable {
    case thin = 0x01
    case fat32 = 0x02
    case fat64 = 0x03
}

enum CodexNodeCodeSignatureValidity: Sendable, Equatable {
    case valid
    case unsigned
    case invalid(status: Int32)
    case unavailable(status: Int32)
}

struct CodexNodeCodeSignatureObservation: Sendable, Equatable {
    let validity: CodexNodeCodeSignatureValidity
    let cdHash: String?
    let informationStatus: Int32?
}

struct CodexNodeCodeSignatureObserving: Sendable {
    private let operation: @Sendable () -> CodexNodeCodeSignatureObservation

    init(_ operation: @escaping @Sendable () -> CodexNodeCodeSignatureObservation) {
        self.operation = operation
    }

    func observe() -> CodexNodeCodeSignatureObservation {
        operation()
    }
}

struct CodexNodeExecutableObservation: Sendable, Equatable {
    let architecture: CodexRuntimeArchitecture
    let machOContainer: CodexNodeMachOContainer
    let containedArchitectures: [CodexRuntimeArchitecture]
    let byteCount: UInt64
    let sha256: String
    let ownerUserID: UInt32
    let permissionMode: UInt16
    let codeSignature: CodexNodeCodeSignatureObservation
}

enum CodexNodeExecutableInspectionLimits {
    static let maximumAbsolutePathBytes = Int(PATH_MAX) - 1
    static let maximumExecutableBytes: UInt64 = 512 * 1024 * 1024
    static let maximumMachOSliceCount = 64
    static let maximumMachOLoadCommandCount = 4096
    static let hashBufferBytes = 64 * 1024

    static func validateExecutableByteCount(_ byteCount: UInt64) throws {
        guard byteCount > 0, byteCount <= maximumExecutableBytes else {
            throw CodexNodeExecutableInspectionError.resourceLimit
        }
    }
}

struct CodexNodeExecutableInspectorTestingHooks: Sendable {
    let afterInitialLstat: (@Sendable () -> Void)?
    let afterFileContentRead: (@Sendable () -> Void)?
    let afterCodeSignatureObservation: (@Sendable () -> Void)?

    init(
        afterInitialLstat: (@Sendable () -> Void)? = nil,
        afterFileContentRead: (@Sendable () -> Void)? = nil,
        afterCodeSignatureObservation: (@Sendable () -> Void)? = nil
    ) {
        self.afterInitialLstat = afterInitialLstat
        self.afterFileContentRead = afterFileContentRead
        self.afterCodeSignatureObservation = afterCodeSignatureObservation
    }

    static let none = Self()
}

enum CodexNodeExecutableInspector {
    static func inspect(
        absolutePath: String,
        requestedArchitecture: CodexRuntimeArchitecture,
        testingHooks: CodexNodeExecutableInspectorTestingHooks = .none
    ) throws -> CodexNodeExecutableObservation {
        let codeSignatureObserver = CodexNodeCodeSignatureObserving {
            CodexNodeCodeSignatureInspector.observe(
                absolutePath: absolutePath,
                requestedArchitecture: requestedArchitecture
            )
        }
        return try inspect(
            absolutePath: absolutePath,
            requestedArchitecture: requestedArchitecture,
            testingHooks: testingHooks,
            codeSignatureObserver: codeSignatureObserver
        )
    }

    static func inspect(
        absolutePath: String,
        requestedArchitecture: CodexRuntimeArchitecture,
        testingHooks: CodexNodeExecutableInspectorTestingHooks,
        codeSignatureObserver: CodexNodeCodeSignatureObserving
    ) throws -> CodexNodeExecutableObservation {
        try CodexNodeExecutableFileIO.inspect(
            absolutePath: absolutePath,
            requestedArchitecture: requestedArchitecture,
            testingHooks: testingHooks,
            codeSignatureObserver: codeSignatureObserver
        )
    }
}
