import Darwin
import Foundation
@testable import FUMINIWAExperimental
import Testing

@Suite("Codex suspended-process identity probe", .serialized)
struct CodexSuspendedProcessIdentityTests {
    @Test("OS signed helperをhost requested architectureで停止中観測して必ずreapする")
    func observesRequestedArchitectureWithoutResuming() async throws {
        let architecture = suspendedTestArchitecture
        let fixture = try systemSuspendedProcessFixture(architecture: architecture)
        let request = try suspendedProcessRequest(fixture: fixture)
        let processID = SuspendedProcessPIDCapture()
        let preflight = SuspendedProcessHookCounter()
        let spawned = SuspendedProcessHookCounter()
        let beforeIdentity = SuspendedProcessHookCounter()
        let afterIdentity = SuspendedProcessHookCounter()
        let cleanup = SuspendedProcessHookCounter()
        let watchdog = suspendedProcessCleanupWatchdog(
            executablePath: fixture.absolutePath
        )
        defer { watchdog.cancel() }

        let observation = try await CodexSuspendedProcessIdentityInspector().inspect(
            request,
            testingHooks: CodexSuspendedProcessIdentityInspectorTestingHooks(
                afterPreflightInspection: {
                    preflight.increment()
                },
                afterSuspendedSpawn: {
                    spawned.increment()
                    processID.recordStoppedDirectChild(
                        executablePath: fixture.absolutePath
                    )
                },
                beforeActualIdentityInspection: {
                    beforeIdentity.increment()
                },
                afterActualIdentityInspection: {
                    afterIdentity.increment()
                },
                beforeCleanup: {
                    cleanup.increment()
                }
            )
        )

        #expect(observation.architecture == architecture)
        #expect(observation.cdHash == fixture.expectedIdentity.cdHash)
        #expect(preflight.value() == 1)
        #expect(spawned.value() == 1)
        #expect(beforeIdentity.value() == 1)
        #expect(afterIdentity.value() == 1)
        #expect(cleanup.value() == 1)
        try await expectSuspendedProcessWasKilledAndReaped(processID.value())
    }

    @Test("ad-hoc helperはinitializer/main実行前の停止を保ったまま拒否してreapする")
    func rejectsAdHocHelperBeforeAnyUserCodeRuns() async throws {
        let helper = try await makeSyntheticSuspendedProcessHelper()
        defer { helper.remove() }
        let signature = CodexNodeCodeSignatureInspector.observe(
            absolutePath: helper.executable.path,
            requestedArchitecture: suspendedTestArchitecture
        )
        let cdHash = try #require(signature.cdHash)
        let expected = try CodexSuspendedProcessExpectedIdentity(
            architecture: suspendedTestArchitecture,
            cdHash: cdHash
        )
        let request = try CodexSuspendedProcessIdentityRequest(
            absolutePath: helper.executable.path,
            expectedIdentity: expected,
            timeout: .seconds(2)
        )
        let processID = SuspendedProcessPIDCapture()
        let afterSpawn = SuspendedProcessHookCounter()
        let watchdog = suspendedProcessCleanupWatchdog(
            executablePath: helper.executable.path
        )
        defer { watchdog.cancel() }

        let error = await capturedSuspendedProcessError {
            _ = try await CodexSuspendedProcessIdentityInspector().inspect(
                request,
                testingHooks: CodexSuspendedProcessIdentityInspectorTestingHooks(
                    afterSuspendedSpawn: {
                        afterSpawn.increment()
                        processID.recordStoppedDirectChild(
                            executablePath: helper.executable.path
                        )
                        expectSyntheticUserCodeDidNotRun(helper)
                    }
                )
            )
        }

        #expect(error == .adHocCodeSignature)
        #expect(afterSpawn.value() == 1)
        expectSyntheticUserCodeDidNotRun(helper)
        try await expectSuspendedProcessWasKilledAndReaped(processID.value())
    }

    @Test("request/resultは実行継続capabilityを公開せずproduction catalogも空のまま")
    func exposesNoContinuationCapability() throws {
        let fixture = try systemSuspendedProcessFixture()
        let request = try suspendedProcessRequest(fixture: fixture)
        let observation = CodexSuspendedProcessIdentityObservation(
            architecture: fixture.expectedIdentity.architecture,
            cdHash: fixture.expectedIdentity.cdHash
        )

        #expect(Mirror(reflecting: request).children.compactMap(\.label) == [
            "absolutePath",
            "expectedIdentity",
            "timeout"
        ])
        #expect(Mirror(reflecting: observation).children.compactMap(\.label) == [
            "architecture",
            "cdHash"
        ])
        let hooks = CodexSuspendedProcessIdentityInspectorTestingHooks.none
        let hookFields = Mirror(reflecting: hooks).children
        #expect(hookFields.compactMap(\.label) == [
            "afterPreflightInspection",
            "beforeSuspendedSpawn",
            "afterSuspendedSpawn",
            "beforeActualIdentityInspection",
            "afterActualIdentityInspection",
            "beforeCleanup"
        ])
        #expect(hookFields.allSatisfy { field in
            let typeName = String(reflecting: type(of: field.value)).lowercased()
            return !typeName.contains("pid")
                && !typeName.contains("processidentity")
                && !typeName.contains("filedescriptor")
        })
        let forbiddenResultLabels = [
            "pid", "process", "path", "descriptor", "fd", "handle",
            "resume", "continuation", "callback", "capability"
        ]
        let resultLabels = Mirror(reflecting: observation).children
            .compactMap(\.label)
            .map { $0.lowercased() }
        #expect(forbiddenResultLabels.allSatisfy { forbidden in
            resultLabels.allSatisfy { !$0.contains(forbidden) }
        })
        #expect(CodexApprovedRuntimeIdentity.ProductionCatalog.approvedPolicyCount == 0)
    }
}
