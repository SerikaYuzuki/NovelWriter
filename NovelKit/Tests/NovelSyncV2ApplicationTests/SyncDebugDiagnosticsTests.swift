import Foundation
import NovelSyncV2
@testable import NovelSyncV2Application
import NovelSyncV2Runtime
import Testing

@Test func syncDebugDiagnosticOmitsAssociatedValues() async throws {
    let config = try TestRuntimeConfiguration()
    let app = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(config))
    let workID = WorkID(UUID())
    await app.recordSyncDiagnostic(workID: workID, stage: "plan-command",
                                   error: SyncV2TypeError.commandViolation("private-payload-secret"))
    let message = try #require(await app.syncDebugDiagnostic(workID: workID))
    #expect(message.contains("plan-command"))
    #expect(message.contains("commandViolation"))
    #expect(!message.contains("private-payload-secret"))
}
