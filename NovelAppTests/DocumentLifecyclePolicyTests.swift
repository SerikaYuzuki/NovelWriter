import Foundation
@testable import FUMINIWA
import NovelSyncV2
import NovelSyncV2Application
import Testing

@MainActor
@Suite("v2 document lifecycle policies")
struct DocumentLifecyclePolicyTests {
    @Test("mutationは終了・切替中または古いsessionを拒否する")
    func mutationRequiresCurrentLifecycle() {
        let state = AppState(
            dependencies: AppDependencies(),
            initialStartupState: .ready
        )
        let session = state.documentSessionToken

        #expect(state.permitsMutation(expectedSession: session))
        state.isTerminationPending = true
        #expect(!state.permitsMutation(expectedSession: session))
        state.isTerminationPending = false
        state.isDocumentTransitionInProgress = true
        #expect(!state.permitsMutation(expectedSession: session))
        state.isDocumentTransitionInProgress = false
        #expect(!state.permitsMutation(expectedSession: AppDocumentSessionToken(
            generation: session.generation + 1,
            documentID: session.documentID,
            workID: session.workID
        )))
    }

    @Test("Editor同期は終了要求後でも同じsessionを受け入れ、切替中は拒否する")
    func editorSynchronizationKeepsFinalCallbackBoundary() {
        let state = AppState(
            dependencies: AppDependencies(),
            initialStartupState: .ready
        )
        let session = state.documentSessionToken
        state.isTerminationPending = true
        #expect(!state.permitsEditorSynchronization(expectedSession: session))
        state.isTerminationPending = false
        #expect(state.permitsEditorSynchronization(expectedSession: session))
        state.isDocumentTransitionInProgress = true
        #expect(!state.permitsEditorSynchronization(expectedSession: session))
    }

    @Test("safe adoption gateはIME/dirty/pending proofをすべて要求する")
    func safeAdoptionGateRequiresMeasuredProof() async throws {
        let gate = MacSyncV2DocumentGate()
        let session = await gate.beginSession(workID: WorkID(UUID()))
        let version = SyncV2LocalVersion(generation: 1, snapshotID: nil)
        let rejected = SyncV2SafeBoundaryProof(
            editorGeneration: 1,
            hasMarkedText: false,
            hasUnsavedChanges: false,
            pendingIntentCleared: false
        )
        await #expect(throws: SyncV2ApplicationError.self) {
            try await gate.arm(session: session, expectedLocalVersion: version, proof: rejected)
        }

        let accepted = SyncV2SafeBoundaryProof(
            editorGeneration: 1,
            hasMarkedText: false,
            hasUnsavedChanges: false,
            pendingIntentCleared: true
        )
        try await gate.arm(session: session, expectedLocalVersion: version, proof: accepted)
    }
}
