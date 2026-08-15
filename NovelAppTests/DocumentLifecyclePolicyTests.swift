import Foundation
@testable import FUMINIWA
import Testing

@Suite("Document lifecycle policies")
struct DocumentLifecyclePolicyTests {
    @Test("mutationは終了・切替中または古いsessionを拒否する")
    func mutationRequiresCurrentLifecycle() {
        let session = DocumentSessionToken(
            generation: 1,
            documentID: UUID(),
            documentURL: URL(fileURLWithPath: "/tmp/work.novelpkg")
        )

        #expect(DocumentLifecyclePermissionPolicy.permitsMutation(
            currentSession: session,
            expectedSession: session,
            isTerminationPending: false,
            isDocumentTransitionInProgress: false
        ))
        #expect(!DocumentLifecyclePermissionPolicy.permitsMutation(
            currentSession: session,
            expectedSession: nil,
            isTerminationPending: true,
            isDocumentTransitionInProgress: false
        ))
        #expect(!DocumentLifecyclePermissionPolicy.permitsMutation(
            currentSession: session,
            expectedSession: DocumentSessionToken(
                generation: 2,
                documentID: session.documentID,
                documentURL: session.documentURL
            ),
            isTerminationPending: false,
            isDocumentTransitionInProgress: false
        ))
    }

    @Test("Editor同期は終了要求後でも同じsessionを受け入れ、切替中は拒否する")
    func editorSynchronizationKeepsFinalCallbackBoundary() {
        let session = DocumentSessionToken(
            generation: 1,
            documentID: UUID(),
            documentURL: URL(fileURLWithPath: "/tmp/work.novelpkg")
        )

        #expect(DocumentLifecyclePermissionPolicy.permitsEditorSynchronization(
            currentSession: session,
            expectedSession: session,
            isTerminationPending: true,
            isDocumentTransitionInProgress: false
        ))
        #expect(!DocumentLifecyclePermissionPolicy.permitsEditorSynchronization(
            currentSession: session,
            expectedSession: nil,
            isTerminationPending: false,
            isDocumentTransitionInProgress: true
        ))
    }

    @Test("packageの親子URL重複を拒否し、別兄弟URLは許可する")
    func detectsOverlappingURLs() {
        let root = URL(fileURLWithPath: "/tmp/library")
        let package = root.appendingPathComponent("work.novelpkg")
        let sibling = URL(fileURLWithPath: "/tmp/exports/work.novelpkg")

        #expect(DocumentURLPolicy.urlsOverlap(root, package))
        #expect(DocumentURLPolicy.urlsOverlap(package, root))
        #expect(!DocumentURLPolicy.urlsOverlap(package, sibling))
    }
}
