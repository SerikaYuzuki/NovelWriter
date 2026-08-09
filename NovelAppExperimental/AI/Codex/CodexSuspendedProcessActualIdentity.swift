import Darwin
import Foundation
import Security

#if !FUMINIWA_ENABLE_EXPERIMENTAL_AI
#error("Codex suspended-process inspection must only compile in FUMINIWAExperimental")
#endif

struct CodexSuspendedProcessActualIdentity {
    let architecture: CodexRuntimeArchitecture
    let cdHash: String
}

private struct CodexSuspendedProcessKernelSnapshot: Equatable {
    let processID: UInt32
    let parentProcessID: UInt32
    let processGroupID: UInt32
    let effectiveUserID: uid_t
    let realUserID: uid_t
    let savedUserID: uid_t
    let effectiveGroupID: gid_t
    let realGroupID: gid_t
    let savedGroupID: gid_t
    let status: UInt32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let flags: UInt32
    let cpuType: cpu_type_t
    let cpuSubtype: cpu_subtype_t
    let executablePath: String
}

private struct CodexSuspendedDynamicSigningObservation {
    let flags: UInt32
    let status: UInt32
    let cdHash: String
}

private struct CodexSuspendedActualContext {
    let processID: pid_t
    let absolutePath: String
    let expectedIdentity: CodexSuspendedProcessExpectedIdentity
    let deadline: ContinuousClock.Instant
    let state: CodexSuspendedProcessLifecycleState
}

// The explicit name distinguishes the dynamic PID guest from static inspection.
// swiftlint:disable:next type_name
enum CodexSuspendedProcessActualIdentityInspector {
    private static let codeSignatureAdHocFlag: UInt32 = 0x0002
    private static let dynamicCodeValidFlag: UInt32 = 0x0000_0001

    static func inspect(
        processID: pid_t,
        absolutePath: String,
        expectedIdentity: CodexSuspendedProcessExpectedIdentity,
        deadline: ContinuousClock.Instant,
        state: CodexSuspendedProcessLifecycleState
    ) throws -> CodexSuspendedProcessActualIdentity {
        let context = CodexSuspendedActualContext(
            processID: processID,
            absolutePath: absolutePath,
            expectedIdentity: expectedIdentity,
            deadline: deadline,
            state: state
        )
        try state.requireInspectionAllowed(deadline: deadline)
        let before = try kernelSnapshot(context)
        try validateKernelSnapshot(before, context: context)
        try state.requireInspectionAllowed(deadline: deadline)

        let dynamicCDHash = try inspectDynamicCode(context)
        try state.requireInspectionAllowed(deadline: deadline)

        let after = try kernelSnapshot(context)
        try validateKernelSnapshot(after, context: context)
        guard before == after else {
            throw CodexSuspendedProcessIdentityInspectionError.processIdentityMismatch
        }
        try state.requireInspectionAllowed(deadline: deadline)

        return CodexSuspendedProcessActualIdentity(
            architecture: expectedIdentity.architecture,
            cdHash: dynamicCDHash
        )
    }
}

private extension CodexSuspendedProcessActualIdentityInspector {
    private static func kernelSnapshot(
        _ context: CodexSuspendedActualContext
    ) throws -> CodexSuspendedProcessKernelSnapshot {
        try context.state.requireInspectionAllowed(deadline: context.deadline)
        let bsd = try bsdInformation(processID: context.processID)
        try context.state.requireInspectionAllowed(deadline: context.deadline)
        let architecture = try architectureInformation(processID: context.processID)
        try context.state.requireInspectionAllowed(deadline: context.deadline)
        let path = try executablePath(processID: context.processID)
        try context.state.requireInspectionAllowed(deadline: context.deadline)

        return CodexSuspendedProcessKernelSnapshot(
            processID: bsd.pbi_pid,
            parentProcessID: bsd.pbi_ppid,
            processGroupID: bsd.pbi_pgid,
            effectiveUserID: bsd.pbi_uid,
            realUserID: bsd.pbi_ruid,
            savedUserID: bsd.pbi_svuid,
            effectiveGroupID: bsd.pbi_gid,
            realGroupID: bsd.pbi_rgid,
            savedGroupID: bsd.pbi_svgid,
            status: bsd.pbi_status,
            startSeconds: bsd.pbi_start_tvsec,
            startMicroseconds: bsd.pbi_start_tvusec,
            flags: bsd.pbi_flags,
            cpuType: architecture.p_cputype,
            cpuSubtype: architecture.p_cpusubtype,
            executablePath: path
        )
    }

    private static func bsdInformation(
        processID: pid_t
    ) throws -> proc_bsdinfo {
        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let bsdResult = withUnsafeMutablePointer(to: &bsd) {
            proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, $0, bsdSize)
        }
        guard bsdResult == bsdSize else {
            throw CodexSuspendedProcessIdentityInspectionError.processIdentityUnavailable(
                operation: "proc_pidinfo(PROC_PIDTBSDINFO)",
                code: bsdResult == -1 ? errno : EIO
            )
        }
        return bsd
    }

    private static func architectureInformation(
        processID: pid_t
    ) throws -> proc_archinfo {
        var architecture = proc_archinfo()
        let architectureSize = Int32(MemoryLayout<proc_archinfo>.size)
        let architectureResult = withUnsafeMutablePointer(to: &architecture) {
            proc_pidinfo(processID, PROC_PIDARCHINFO, 0, $0, architectureSize)
        }
        guard architectureResult == architectureSize else {
            throw CodexSuspendedProcessIdentityInspectionError.processIdentityUnavailable(
                operation: "proc_pidinfo(PROC_PIDARCHINFO)",
                code: architectureResult == -1 ? errno : EIO
            )
        }
        return architecture
    }

    private static func executablePath(
        processID: pid_t
    ) throws -> String {
        var pathBuffer = [CChar](
            repeating: 0,
            count: Int(MAXPATHLEN) * 4
        )
        let pathResult = pathBuffer.withUnsafeMutableBytes { buffer -> Int32 in
            guard let baseAddress = buffer.baseAddress else { return -1 }
            return proc_pidpath(
                processID,
                baseAddress,
                UInt32(buffer.count)
            )
        }
        guard pathResult > 0 else {
            throw CodexSuspendedProcessIdentityInspectionError.processIdentityUnavailable(
                operation: "proc_pidpath",
                code: errno
            )
        }
        let path = pathBuffer.withUnsafeBufferPointer { buffer in
            buffer.baseAddress.flatMap(String.init(validatingCString:))
        }
        guard let path else {
            throw CodexSuspendedProcessIdentityInspectionError.processIdentityUnavailable(
                operation: "proc_pidpath(UTF-8)",
                code: EILSEQ
            )
        }
        return path
    }

    private static func validateKernelSnapshot(
        _ snapshot: CodexSuspendedProcessKernelSnapshot,
        context: CodexSuspendedActualContext
    ) throws {
        let hasExpectedProcessIdentity = snapshot.processID == UInt32(context.processID)
            && snapshot.parentProcessID == UInt32(Darwin.getpid())
            && snapshot.processGroupID == UInt32(context.processID)
            && snapshot.effectiveUserID == Darwin.geteuid()
            && snapshot.realUserID == Darwin.getuid()
            && snapshot.savedUserID == Darwin.geteuid()
            && snapshot.effectiveGroupID == Darwin.getegid()
            && snapshot.realGroupID == Darwin.getgid()
            && snapshot.savedGroupID == Darwin.getegid()
            && snapshot.startSeconds > 0
            && Array(snapshot.executablePath.utf8) == Array(context.absolutePath.utf8)
        guard hasExpectedProcessIdentity else {
            throw CodexSuspendedProcessIdentityInspectionError.processIdentityMismatch
        }
        guard snapshot.status == UInt32(SSTOP) else {
            throw CodexSuspendedProcessIdentityInspectionError.processWasNotSuspended
        }
        try context.state.requireInspectionAllowed(deadline: context.deadline)
        errno = 0
        let groupID = Darwin.getpgid(context.processID)
        guard groupID == context.processID else {
            throw CodexSuspendedProcessIdentityInspectionError.processIdentityUnavailable(
                operation: "getpgid(suspended child)",
                code: groupID == -1 ? errno : EPERM
            )
        }
        guard runtimeArchitecture(snapshot.cpuType) == context.expectedIdentity.architecture else {
            throw CodexSuspendedProcessIdentityInspectionError.processIdentityMismatch
        }
    }
}

private extension CodexSuspendedProcessActualIdentityInspector {
    private static func inspectDynamicCode(
        _ context: CodexSuspendedActualContext
    ) throws -> String {
        try context.state.requireInspectionAllowed(deadline: context.deadline)
        let dynamicCode = try copyDynamicCode(processID: context.processID)
        try context.state.requireInspectionAllowed(deadline: context.deadline)
        let requirement = try makeCDHashRequirement(context.expectedIdentity.cdHash)
        try context.state.requireInspectionAllowed(deadline: context.deadline)
        try requireValidDynamicCode(dynamicCode, requirement: requirement)
        try context.state.requireInspectionAllowed(deadline: context.deadline)

        let staticCode = unsafeBitCast(dynamicCode, to: SecStaticCode.self)
        let signing = try signingObservation(staticCode)
        guard signing.flags & codeSignatureAdHocFlag == 0 else {
            throw CodexSuspendedProcessIdentityInspectionError.adHocCodeSignature
        }
        guard signing.status & dynamicCodeValidFlag != 0 else {
            throw CodexSuspendedProcessIdentityInspectionError.invalidCodeSignature(
                status: errSecCSInvalidObjectRef
            )
        }
        guard signing.cdHash == context.expectedIdentity.cdHash else {
            throw CodexSuspendedProcessIdentityInspectionError.processIdentityMismatch
        }
        try context.state.requireInspectionAllowed(deadline: context.deadline)
        try requireDynamicCodePath(staticCode, absolutePath: context.absolutePath)
        try context.state.requireInspectionAllowed(deadline: context.deadline)
        return signing.cdHash
    }

    private static func copyDynamicCode(processID: pid_t) throws -> SecCode {
        var dynamicCode: SecCode?
        let guestStatus = SecCodeCopyGuestWithAttributes(
            nil,
            [kSecGuestAttributePid: NSNumber(value: processID)] as CFDictionary,
            SecCSFlags(rawValue: 0),
            &dynamicCode
        )
        guard guestStatus == errSecSuccess, let dynamicCode else {
            throw CodexSuspendedProcessIdentityInspectionError.invalidCodeSignature(
                status: guestStatus
            )
        }
        return dynamicCode
    }

    private static func makeCDHashRequirement(
        _ expectedCDHash: String
    ) throws -> SecRequirement {
        var requirement: SecRequirement?
        let requirementText = "cdhash H\"\(expectedCDHash)\"" as CFString
        let requirementStatus = SecRequirementCreateWithString(
            requirementText,
            SecCSFlags(rawValue: 0),
            &requirement
        )
        guard requirementStatus == errSecSuccess, let requirement else {
            throw CodexSuspendedProcessIdentityInspectionError.invalidCodeSignature(
                status: requirementStatus
            )
        }
        return requirement
    }

    private static func requireValidDynamicCode(
        _ dynamicCode: SecCode,
        requirement: SecRequirement
    ) throws {
        let validityStatus = SecCodeCheckValidity(
            dynamicCode,
            SecCSFlags.noNetworkAccess,
            requirement
        )
        guard validityStatus == errSecSuccess else {
            throw CodexSuspendedProcessIdentityInspectionError.invalidCodeSignature(
                status: validityStatus
            )
        }
    }

    private static func signingObservation(
        _ staticCode: SecStaticCode
    ) throws -> CodexSuspendedDynamicSigningObservation {
        var signingInformation: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSDynamicInformation),
            &signingInformation
        )
        guard informationStatus == errSecSuccess else {
            throw CodexSuspendedProcessIdentityInspectionError.invalidCodeSignature(
                status: informationStatus
            )
        }
        guard let information = signingInformation as? [CFString: Any] else {
            throw CodexSuspendedProcessIdentityInspectionError.invalidCodeSignature(
                status: errSecCSInvalidObjectRef
            )
        }
        guard let flags = information[kSecCodeInfoFlags] as? NSNumber else {
            throw CodexSuspendedProcessIdentityInspectionError.invalidCodeSignature(
                status: errSecCSInvalidObjectRef
            )
        }
        guard let dynamicStatus = information[kSecCodeInfoStatus] as? NSNumber else {
            throw CodexSuspendedProcessIdentityInspectionError.invalidCodeSignature(
                status: errSecCSInvalidObjectRef
            )
        }
        guard let cdHashData = information[kSecCodeInfoUnique] as? Data else {
            throw CodexSuspendedProcessIdentityInspectionError.invalidCodeSignature(
                status: errSecCSInvalidObjectRef
            )
        }
        guard cdHashData.count == 20 else {
            throw CodexSuspendedProcessIdentityInspectionError.invalidCodeSignature(
                status: errSecCSInvalidObjectRef
            )
        }
        return CodexSuspendedDynamicSigningObservation(
            flags: flags.uint32Value,
            status: dynamicStatus.uint32Value,
            cdHash: cdHashData.codexRuntimeLowercaseHex
        )
    }

    private static func requireDynamicCodePath(
        _ staticCode: SecStaticCode,
        absolutePath: String
    ) throws {
        var codePath: CFURL?
        let pathStatus = SecCodeCopyPath(
            staticCode,
            SecCSFlags(rawValue: 0),
            &codePath
        )
        let observedPath = (codePath as URL?)?.path
        guard pathStatus == errSecSuccess else {
            throw CodexSuspendedProcessIdentityInspectionError.processIdentityMismatch
        }
        guard let observedPath else {
            throw CodexSuspendedProcessIdentityInspectionError.processIdentityMismatch
        }
        let pathMatches = Array(observedPath.utf8) == Array(absolutePath.utf8)
        guard pathMatches else {
            throw CodexSuspendedProcessIdentityInspectionError.processIdentityMismatch
        }
    }

    private static func runtimeArchitecture(
        _ cpuType: cpu_type_t
    ) -> CodexRuntimeArchitecture? {
        switch cpuType {
        case CPU_TYPE_ARM64:
            .arm64
        case CPU_TYPE_X86_64:
            .x64
        default:
            nil
        }
    }
}
