import Foundation
@testable import FUMINIWA
import NovelCore
import NovelSyncV2
import NovelSyncV2PortableBridge
import Testing

@Suite("macOS Snapshot Sync v2 install validation")
struct SnapshotSyncV2MacInstallValidationTests {
    @Test("invalid portable marker never mutates the active editor")
    @MainActor
    func invalidPortableMarkerFailsClosed() {
        let state = AppState(
            dependencies: AppDependencies(
                userDefaults: makeIsolatedTestUserDefaults()
            ),
            initialStartupState: .ready
        )
        let originalDocument = state.document
        let originalSession = state.documentSessionToken
        let invalidResources = [
            PortableResource(
                pathComponents: SyncV2PortableMetadata.localCreatedAtPath,
                kind: .regularFile,
                bytes: Data("1".utf8)
            ),
            PortableResource(
                pathComponents: SyncV2PortableMetadata.localCreatedAtPath,
                kind: .regularFile,
                bytes: Data("2".utf8)
            )
        ]

        #expect(
            state.installV2Document(
                NovelDocument.newDocument(title: "不正な作品"),
                workID: WorkID(UUID()),
                createdAt: Date(),
                resources: invalidResources
            ) == false
        )
        #expect(state.document == originalDocument)
        #expect(state.documentSessionToken == originalSession)
        #expect(state.snapshotSyncV2Resources.isEmpty)
    }

    @Test("unexpected WorkID and DocumentID never mutate the active editor")
    @MainActor
    func identityMismatchFailsClosed() {
        let state = AppState(
            dependencies: AppDependencies(
                userDefaults: makeIsolatedTestUserDefaults()
            ),
            initialStartupState: .ready
        )
        let originalDocument = state.document
        let originalSession = state.documentSessionToken
        let document = NovelDocument.newDocument(title: "別identity")

        #expect(
            state.installV2Document(
                document,
                workID: WorkID(UUID()),
                createdAt: Date(),
                expectedWorkID: WorkID(UUID()),
                expectedDocumentID: UUID()
            ) == false
        )
        #expect(state.document == originalDocument)
        #expect(state.documentSessionToken == originalSession)
    }
}
