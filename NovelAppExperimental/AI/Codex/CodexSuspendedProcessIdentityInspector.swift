import Darwin
import Foundation

#if !FUMINIWA_ENABLE_EXPERIMENTAL_AI
#error("Codex suspended-process inspection must only compile in FUMINIWAExperimental")
#endif

// Kept explicit because these errors cross the async inspection boundary.
// swiftlint:disable:next type_name
enum CodexSuspendedProcessIdentityInspectionError: Error, Sendable, Equatable {
    case alreadyRunning
    case invalidPath
    case invalidExpectedCDHash
    case invalidTimeout
    case symbolicLink
    case notRegularFile
    case hardLink
    case invalidOwner
    case invalidMode
    case notExecutable
    case resourceLimit
    case cancelled
    case timedOut
    case systemCallFailed(operation: String, code: Int32)
    case processIdentityUnavailable(operation: String, code: Int32)
    case processIdentityMismatch
    case processWasNotSuspended
    case invalidCodeSignature(status: Int32)
    case adHocCodeSignature
    case directChildReapTimedOut
}

/// A caller assertion used only for this non-authority probe. It is not an
/// approval, catalog entry, or permission to launch/resume a process.
struct CodexSuspendedProcessExpectedIdentity: Sendable, Equatable {
    let architecture: CodexRuntimeArchitecture
    let cdHash: String

    init(
        architecture: CodexRuntimeArchitecture,
        cdHash: String
    ) throws {
        guard CodexRuntimeApprovalValidation.decodeLowercaseHex(
            cdHash,
            byteCount: 20
        ) != nil else {
            throw CodexSuspendedProcessIdentityInspectionError.invalidExpectedCDHash
        }
        self.architecture = architecture
        self.cdHash = cdHash
    }
}

struct CodexSuspendedProcessIdentityRequest: Sendable, Equatable {
    static let maximumTimeout: Duration = .seconds(30)

    let absolutePath: String
    let expectedIdentity: CodexSuspendedProcessExpectedIdentity
    let timeout: Duration

    init(
        absolutePath: String,
        expectedIdentity: CodexSuspendedProcessExpectedIdentity,
        timeout: Duration
    ) throws {
        guard absolutePath.hasPrefix("/"), !absolutePath.utf8.contains(0) else {
            throw CodexSuspendedProcessIdentityInspectionError.invalidPath
        }
        guard timeout > .zero, timeout <= Self.maximumTimeout else {
            throw CodexSuspendedProcessIdentityInspectionError.invalidTimeout
        }
        self.absolutePath = absolutePath
        self.expectedIdentity = expectedIdentity
        self.timeout = timeout
    }
}

/// A content-free, non-authority observation. Successful return means the
/// suspended direct child was killed and reaped; no usable process remains.
struct CodexSuspendedProcessIdentityObservation: Sendable, Equatable {
    let architecture: CodexRuntimeArchitecture
    let cdHash: String
}

// The explicit name keeps test-only seams distinct from launch capabilities.
// swiftlint:disable:next type_name
struct CodexSuspendedProcessIdentityInspectorTestingHooks: Sendable {
    let afterPreflightInspection: (@Sendable () -> Void)?
    let beforeSuspendedSpawn: (@Sendable () -> Void)?
    let afterSuspendedSpawn: (@Sendable () -> Void)?
    let beforeActualIdentityInspection: (@Sendable () -> Void)?
    let afterActualIdentityInspection: (@Sendable () -> Void)?
    let beforeCleanup: (@Sendable () -> Void)?

    init(
        afterPreflightInspection: (@Sendable () -> Void)? = nil,
        beforeSuspendedSpawn: (@Sendable () -> Void)? = nil,
        afterSuspendedSpawn: (@Sendable () -> Void)? = nil,
        beforeActualIdentityInspection: (@Sendable () -> Void)? = nil,
        afterActualIdentityInspection: (@Sendable () -> Void)? = nil,
        beforeCleanup: (@Sendable () -> Void)? = nil
    ) {
        self.afterPreflightInspection = afterPreflightInspection
        self.beforeSuspendedSpawn = beforeSuspendedSpawn
        self.afterSuspendedSpawn = afterSuspendedSpawn
        self.beforeActualIdentityInspection = beforeActualIdentityInspection
        self.afterActualIdentityInspection = afterActualIdentityInspection
        self.beforeCleanup = beforeCleanup
    }

    static let none = Self()
}

actor CodexSuspendedProcessIdentityInspector {
    private var currentSession: CodexSuspendedProcessIdentitySession?

    func inspect(
        _ request: CodexSuspendedProcessIdentityRequest,
        testingHooks: CodexSuspendedProcessIdentityInspectorTestingHooks = .none
    ) async throws -> CodexSuspendedProcessIdentityObservation {
        guard currentSession == nil else {
            throw CodexSuspendedProcessIdentityInspectionError.alreadyRunning
        }
        let session = CodexSuspendedProcessIdentitySession(
            request: request,
            testingHooks: testingHooks
        )
        currentSession = session
        defer {
            if currentSession === session {
                currentSession = nil
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                session.start(continuation: continuation)
            }
        } onCancel: {
            session.requestCancellation()
        }
    }

    func cancel() {
        currentSession?.requestCancellation()
    }
}

final class CodexSuspendedProcessIdentitySession: @unchecked Sendable {
    private let request: CodexSuspendedProcessIdentityRequest
    private let testingHooks: CodexSuspendedProcessIdentityInspectorTestingHooks
    private let state = CodexSuspendedProcessLifecycleState()
    private let inspectionQueue = DispatchQueue(
        label: "dev.serikayuzuki.fuminiwa.codex-suspended-process-inspection",
        qos: .userInitiated
    )

    init(
        request: CodexSuspendedProcessIdentityRequest,
        testingHooks: CodexSuspendedProcessIdentityInspectorTestingHooks
    ) {
        self.request = request
        self.testingHooks = testingHooks
    }

    func start(
        continuation: CheckedContinuation<
            CodexSuspendedProcessIdentityObservation,
            any Error
        >
    ) {
        inspectionQueue.async { [request, state, testingHooks] in
            do {
                let observation = try CodexSuspendedProcessIdentityRunner.inspect(
                    request,
                    state: state,
                    testingHooks: testingHooks
                )
                continuation.resume(returning: observation)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func requestCancellation() {
        state.requestCancellation()
    }
}

enum CodexSuspendedProcessIdentityRunner {}
