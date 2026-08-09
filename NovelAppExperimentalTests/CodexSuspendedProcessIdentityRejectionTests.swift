import Darwin
import Foundation
@testable import FUMINIWAExperimental
import Testing

@Suite("Codex suspended-process identity rejection", .serialized)
struct CodexSuspendedRejectionTests {
    @Test("expected CDHashとrequest boundsをspawn前にstrict検査する")
    func validatesExpectedIdentityAndRequestBounds() throws {
        for cdHash in [
            String(repeating: "a", count: 39),
            String(repeating: "a", count: 41),
            String(repeating: "A", count: 40),
            String(repeating: "g", count: 40)
        ] {
            #expect(throws: CodexSuspendedProcessIdentityInspectionError.invalidExpectedCDHash) {
                _ = try CodexSuspendedProcessExpectedIdentity(
                    architecture: suspendedTestArchitecture,
                    cdHash: cdHash
                )
            }
        }

        let expected = try systemSuspendedProcessFixture().expectedIdentity
        for path in ["usr/bin/true", "", "\0/usr/bin/true"] {
            #expect(throws: CodexSuspendedProcessIdentityInspectionError.invalidPath) {
                _ = try CodexSuspendedProcessIdentityRequest(
                    absolutePath: path,
                    expectedIdentity: expected,
                    timeout: .seconds(1)
                )
            }
        }
        for timeout in [
            Duration.zero,
            CodexSuspendedProcessIdentityRequest.maximumTimeout + .nanoseconds(1)
        ] {
            #expect(throws: CodexSuspendedProcessIdentityInspectionError.invalidTimeout) {
                _ = try CodexSuspendedProcessIdentityRequest(
                    absolutePath: "/usr/bin/true",
                    expectedIdentity: expected,
                    timeout: timeout
                )
            }
        }
    }

    @Test("symlink hardlink special file unsafe modeをspawn前に拒否する")
    // swiftlint:disable:next function_body_length
    func rejectsUnsafeFilesystemInputsBeforeSpawn() async throws {
        let root = try makeNodeInspectorTemporaryRoot()
        defer { removeSuspendedProcessTestFixture(at: root) }
        let expected = try systemSuspendedProcessFixture().expectedIdentity
        let afterSpawn = SuspendedProcessHookCounter()

        let symbolicLink = root.appending(path: "symbolic-link")
        guard symlink("/usr/bin/true", symbolicLink.path) == 0 else {
            throw SuspendedProcessTestError.systemCallFailed
        }
        #expect(
            await inspectionError(
                at: symbolicLink,
                expected: expected,
                afterSpawn: afterSpawn
            ) == .symbolicLink
        )

        let hardLinked = root.appending(path: "hard-linked")
        let hardLinkAlias = root.appending(path: "hard-link-alias")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: hardLinked
        )
        let hardLinkModeWasSet = chmod(hardLinked.path, 0o700) == 0
        let hardLinkWasCreated = link(hardLinked.path, hardLinkAlias.path) == 0
        guard hardLinkModeWasSet, hardLinkWasCreated else {
            throw SuspendedProcessTestError.systemCallFailed
        }
        #expect(
            await inspectionError(
                at: hardLinked,
                expected: expected,
                afterSpawn: afterSpawn
            ) == .hardLink
        )

        let unsafeMode = root.appending(path: "unsafe-mode")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: unsafeMode
        )
        guard chmod(unsafeMode.path, 0o722) == 0 else {
            throw SuspendedProcessTestError.systemCallFailed
        }
        #expect(
            await inspectionError(
                at: unsafeMode,
                expected: expected,
                afterSpawn: afterSpawn
            ) == .invalidMode
        )

        let notExecutable = root.appending(path: "not-executable")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: notExecutable
        )
        guard chmod(notExecutable.path, 0o600) == 0 else {
            throw SuspendedProcessTestError.systemCallFailed
        }
        #expect(
            await inspectionError(
                at: notExecutable,
                expected: expected,
                afterSpawn: afterSpawn
            ) == .notExecutable
        )

        let directory = root.appending(path: "directory", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        #expect(
            await inspectionError(
                at: directory,
                expected: expected,
                afterSpawn: afterSpawn
            ) == .notRegularFile
        )

        let oversized = root.appending(path: "oversized-executable")
        #expect(FileManager.default.createFile(atPath: oversized.path, contents: nil))
        let oversizedByteCount = off_t(512 * 1024 * 1024 + 1)
        let oversizedWasTruncated = truncate(oversized.path, oversizedByteCount) == 0
        let oversizedModeWasSet = chmod(oversized.path, 0o700) == 0
        guard oversizedWasTruncated, oversizedModeWasSet else {
            throw SuspendedProcessTestError.systemCallFailed
        }
        #expect(
            await inspectionError(
                at: oversized,
                expected: expected,
                afterSpawn: afterSpawn
            ) == .resourceLimit
        )
        #expect(afterSpawn.value() == 0)
    }

    @Test("wrong dynamic CDHashは停止childをresumeせずreapして拒否する")
    func rejectsWrongDynamicCDHashAndReaps() async throws {
        let fixture = try systemSuspendedProcessFixture()
        let wrongHash = replacingFirstHexDigit(fixture.expectedIdentity.cdHash)
        let wrongExpected = try CodexSuspendedProcessExpectedIdentity(
            architecture: fixture.expectedIdentity.architecture,
            cdHash: wrongHash
        )
        let request = try CodexSuspendedProcessIdentityRequest(
            absolutePath: fixture.absolutePath,
            expectedIdentity: wrongExpected,
            timeout: .seconds(2)
        )
        let processID = SuspendedProcessPIDCapture()
        let watchdog = suspendedProcessCleanupWatchdog(
            executablePath: fixture.absolutePath
        )
        defer { watchdog.cancel() }

        let error = await capturedSuspendedProcessError {
            _ = try await CodexSuspendedProcessIdentityInspector().inspect(
                request,
                testingHooks: CodexSuspendedProcessIdentityInspectorTestingHooks(
                    afterSuspendedSpawn: {
                        processID.recordStoppedDirectChild(
                            executablePath: fixture.absolutePath
                        )
                    }
                )
            )
        }

        #expect(isDynamicIdentityMismatch(error))
        try await expectSuspendedProcessWasKilledAndReaped(processID.value())
    }

    @Test("path A/B swapとswap-backでもactual child identityの不一致を拒否する")
    func rejectsPathSwapAndSwapBack() async throws {
        for restoresPathAfterSpawn in [false, true] {
            let fixture = try await makeSuspendedProcessPathSwapFixture()
            defer { fixture.remove() }
            let request = try CodexSuspendedProcessIdentityRequest(
                absolutePath: fixture.launchPath.path,
                expectedIdentity: fixture.expectedIdentity,
                timeout: .seconds(2)
            )
            let processID = SuspendedProcessPIDCapture()
            let watchdog = suspendedProcessCleanupWatchdog(
                executablePath: fixture.launchPath.path
            )
            defer { watchdog.cancel() }

            let error = await capturedSuspendedProcessError {
                _ = try await CodexSuspendedProcessIdentityInspector().inspect(
                    request,
                    testingHooks: CodexSuspendedProcessIdentityInspectorTestingHooks(
                        beforeSuspendedSpawn: {
                            fixture.installReplacement()
                        },
                        afterSuspendedSpawn: {
                            processID.recordStoppedDirectChild(
                                executablePath: fixture.launchPath.path
                            )
                            fixture.expectUserCodeDidNotRun()
                            if restoresPathAfterSpawn {
                                fixture.restoreOriginalPath()
                            }
                        }
                    )
                )
            }

            #expect(isDynamicIdentityMismatch(error))
            fixture.expectUserCodeDidNotRun()
            try await expectSuspendedProcessWasKilledAndReaped(processID.value())
        }
    }

    private func inspectionError(
        at url: URL,
        expected: CodexSuspendedProcessExpectedIdentity,
        afterSpawn: SuspendedProcessHookCounter
    ) async -> CodexSuspendedProcessIdentityInspectionError? {
        await capturedSuspendedProcessError {
            let request = try CodexSuspendedProcessIdentityRequest(
                absolutePath: url.path,
                expectedIdentity: expected,
                timeout: .seconds(1)
            )
            _ = try await CodexSuspendedProcessIdentityInspector().inspect(
                request,
                testingHooks: CodexSuspendedProcessIdentityInspectorTestingHooks(
                    afterSuspendedSpawn: {
                        afterSpawn.increment()
                    }
                )
            )
        }
    }

    private func replacingFirstHexDigit(_ value: String) -> String {
        let replacement = value.first == "0" ? "1" : "0"
        return replacement + value.dropFirst()
    }

    private func isDynamicIdentityMismatch(
        _ error: CodexSuspendedProcessIdentityInspectionError?
    ) -> Bool {
        switch error {
        case .processIdentityMismatch, .invalidCodeSignature:
            true
        default:
            false
        }
    }
}
