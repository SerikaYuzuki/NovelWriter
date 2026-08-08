import CryptoKit
import EditorKit
import Foundation
import NovelAI
import NovelCore

enum AIProofreadingPhase: Equatable {
    case idle
    case preview
    case running
    case cancelling
    case result
    case applied
    case failed
    case cancelled
    case invalidated
}

enum AIProofreadingStaleReason: Equatable {
    case appUnavailable
    case documentChanged
    case episodeChanged
    case providerChanged
    case sourceChanged
    case editorChanged(EditorAISelectionError)
}

enum AIProofreadingFailure: Equatable {
    case editor(EditorAISelectionError)
    case request(AIError)
    case stale(AIProofreadingStaleReason)
}

struct AIProofreadingProgress: Equatable {
    var unverifiedReplacement = ""
}

struct AIProofreadingResultPresentation: Equatable {
    let source: String
    let result: AIResult
    var staleReason: AIProofreadingStaleReason?

    var canApply: Bool {
        staleReason == nil && result.replacement != source
    }
}

struct AIProofreadingDocumentSnapshot: Equatable {
    let session: DocumentSessionToken
    let chapterID: ChapterID
    let episodeID: EpisodeID
}

@MainActor
struct AIProofreadingDocumentContextClient {
    let currentSnapshot: @MainActor () -> AIProofreadingDocumentSnapshot?

    init(appState: AppState) {
        currentSnapshot = { [weak appState] in
            guard let appState,
                  appState.permitsLongRunningDocumentOperation,
                  let chapterID = appState.selectedChapterID,
                  let episodeID = appState.selectedEpisodeID,
                  appState.document.chapters.contains(where: { chapter in
                      chapter.id == chapterID && chapter.episodes.contains(where: { $0.id == episodeID })
                  }) else { return nil }
            return AIProofreadingDocumentSnapshot(
                session: appState.documentSessionToken,
                chapterID: chapterID,
                episodeID: episodeID
            )
        }
    }

    init(currentSnapshot: @escaping @MainActor () -> AIProofreadingDocumentSnapshot?) {
        self.currentSnapshot = currentSnapshot
    }
}

@MainActor
struct AIEditorSelectionHandle {
    let id: UUID
    let selectedText: String
    let validate: @MainActor () -> Result<Void, EditorAISelectionError>
    let replace: @MainActor (String) -> Result<Void, EditorAISelectionError>
}

@MainActor
struct AIEditorSelectionClient {
    let capture: @MainActor () -> Result<AIEditorSelectionHandle, EditorAISelectionError>

    init(session: EditorAISelectionSession) {
        capture = {
            session.captureSelection().map { transaction in
                AIEditorSelectionHandle(
                    id: transaction.id,
                    selectedText: transaction.selectedText,
                    validate: { session.validate(transaction) },
                    replace: { replacement in
                        session.replace(transaction, with: replacement)
                    }
                )
            }
        }
    }

    init(capture: @escaping @MainActor () -> Result<AIEditorSelectionHandle, EditorAISelectionError>) {
        self.capture = capture
    }
}

struct AIProofreadingSourceDigest: Equatable {
    private let bytes: Data

    init(exactText: String) {
        bytes = Data(SHA256.hash(data: Data(exactText.utf8)))
    }
}

struct AIProviderDisclosureSnapshot: Sendable, Equatable {
    let revision: String
    let summary: String
    let limitations: [String]
    let isDevelopmentFake: Bool
}

struct AIProviderRoute: Sendable {
    let leaseID: UUID
    let descriptor: AIProviderDescriptor
    let disclosure: AIProviderDisclosureSnapshot

    private let eventFactory: @Sendable (AIConfirmedRequest) -> AIProviderEventStream
    private let runtimeShutdown: @Sendable () async -> Void

    init(
        leaseID: UUID = UUID(),
        provider: some AIProvider,
        disclosure: AIProviderDisclosureSnapshot,
        runtimeShutdown: @escaping @Sendable () async -> Void = {}
    ) {
        self.leaseID = leaseID
        descriptor = provider.descriptor
        self.disclosure = disclosure
        eventFactory = { request in
            AIProviderExecutor.events(for: request, using: provider)
        }
        self.runtimeShutdown = runtimeShutdown
    }

    func events(for request: AIConfirmedRequest) -> AIProviderEventStream {
        eventFactory(request)
    }

    func shutdownAndDrainRuntime() async {
        await runtimeShutdown()
    }
}
