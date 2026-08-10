import EditorKit
import NovelCore
import Observation

struct IOSWorkspaceEditorDeparture: Equatable {
    let documentID: IOSPrivateDocumentID
    let chapterID: ChapterID?
    let episodeID: EpisodeID?
}

enum IOSWorkspaceRoute: Hashable {
    case projectHome(documentID: IOSPrivateDocumentID)
    case projectInfo(documentID: IOSPrivateDocumentID)
    case writing(documentID: IOSPrivateDocumentID)
    case editor(
        documentID: IOSPrivateDocumentID,
        chapterID: ChapterID,
        episodeID: EpisodeID
    )

    var documentID: IOSPrivateDocumentID {
        switch self {
        case let .projectHome(documentID),
             let .projectInfo(documentID),
             let .writing(documentID),
             let .editor(documentID, _, _):
            documentID
        }
    }
}

@MainActor
@Observable
final class IOSWorkspaceNavigationCoordinator {
    private(set) var path: [IOSWorkspaceRoute] = []
    private(set) var activeDocumentID: IOSPrivateDocumentID?

    var activeEditorDeparture: IOSWorkspaceEditorDeparture? {
        Self.editorDeparture(in: path)
    }

    func showProjectHome(for documentID: IOSPrivateDocumentID) {
        activeDocumentID = documentID
        path = [.projectHome(documentID: documentID)]
    }

    func showProjectInfo(for documentID: IOSPrivateDocumentID) {
        prepareProjectPath(for: documentID)
        path.append(.projectInfo(documentID: documentID))
    }

    func showWriting(for documentID: IOSPrivateDocumentID) {
        prepareProjectPath(for: documentID)
        path.append(.writing(documentID: documentID))
    }

    func showEditor(
        for documentID: IOSPrivateDocumentID,
        chapterID: ChapterID,
        episodeID: EpisodeID
    ) {
        prepareProjectPath(for: documentID)
        if path.last != .writing(documentID: documentID) {
            path.append(.writing(documentID: documentID))
        }
        path.append(
            .editor(
                documentID: documentID,
                chapterID: chapterID,
                episodeID: episodeID
            )
        )
    }

    func documentDidChange(to documentID: IOSPrivateDocumentID) {
        let containsStaleRoute = path.contains { $0.documentID != documentID }
        guard activeDocumentID != documentID || containsStaleRoute else { return }

        activeDocumentID = documentID
        if !path.isEmpty {
            path = [.projectHome(documentID: documentID)]
        }
    }

    @discardableResult
    func updatePath(
        _ newPath: [IOSWorkspaceRoute],
        beforeEditorDeparture: (IOSWorkspaceEditorDeparture) -> Bool
    ) -> Bool {
        guard newPath != path else { return true }

        let retainedCount = zip(path, newPath)
            .prefix { current, proposed in current == proposed }
            .count
        let removedRoutes = Array(path.dropFirst(retainedCount))
        let departure = Self.editorDeparture(in: removedRoutes)
        if let departure, !beforeEditorDeparture(departure) {
            return false
        }

        path = newPath
        if let documentID = newPath.last?.documentID {
            activeDocumentID = documentID
        }
        return true
    }

    private func prepareProjectPath(for documentID: IOSPrivateDocumentID) {
        activeDocumentID = documentID
        let startsAtProjectHome = path.first == .projectHome(documentID: documentID)
        let containsOnlyCurrentDocument = path.allSatisfy { $0.documentID == documentID }
        guard startsAtProjectHome, containsOnlyCurrentDocument else {
            path = [.projectHome(documentID: documentID)]
            return
        }
    }

    private static func editorDeparture(
        in routes: [IOSWorkspaceRoute]
    ) -> IOSWorkspaceEditorDeparture? {
        for route in routes.reversed() {
            if case let .editor(documentID, chapterID, episodeID) = route {
                return IOSWorkspaceEditorDeparture(
                    documentID: documentID,
                    chapterID: chapterID,
                    episodeID: episodeID
                )
            }
        }
        for route in routes.reversed() {
            if case let .writing(documentID) = route {
                return IOSWorkspaceEditorDeparture(
                    documentID: documentID,
                    chapterID: nil,
                    episodeID: nil
                )
            }
        }
        return nil
    }
}

@MainActor
enum IOSWorkspaceEditorSynchronizer {
    @discardableResult
    static func synchronize(
        store: IOSDocumentStore,
        departure: IOSWorkspaceEditorDeparture
    ) -> Bool {
        guard store.documentURL.lastPathComponent == departure.documentID.packageName else {
            return true
        }
        if store.isDocumentTransitionInProgress {
            return store.editorCommandSession.isDocumentTransitionPrepared
        }
        let chapterID = departure.chapterID ?? store.selectedChapterID
        let episodeID = departure.episodeID ?? store.selectedEpisodeID
        guard let chapterID, let episodeID else {
            return true
        }

        guard store.editorCommandSession.prepareForDocumentTransition() else {
            store.operationErrorMessage = "日本語入力を確定できませんでした。変換を確定してから、もう一度お試しください。"
            return false
        }
        defer {
            store.editorCommandSession.resumeAfterDocumentTransition()
        }

        switch store.editorCommandSession.captureActiveCommittedText() {
        case let .captured(text):
            guard store.documentURL.lastPathComponent == departure.documentID.packageName else {
                return true
            }
            store.updateEpisodeContent(
                text,
                chapterID: chapterID,
                episodeID: episodeID
            )
            return true
        case .compositionInProgress:
            store.operationErrorMessage = "日本語入力を確定できませんでした。変換を確定してから、もう一度お試しください。"
            return false
        case .notActive:
            return true
        }
    }
}
