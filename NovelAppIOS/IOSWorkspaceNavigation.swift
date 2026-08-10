import EditorKit
import NovelCore
import Observation

struct IOSWorkspaceEditorDeparture: Equatable {
    let session: IOSDocumentSessionToken
    let chapterID: ChapterID?
    let episodeID: EpisodeID?
}

enum IOSWorkspaceRoute: Hashable {
    case projectHome(session: IOSDocumentSessionToken)
    case projectInfo(session: IOSDocumentSessionToken)
    case writing(session: IOSDocumentSessionToken)
    case plot(session: IOSDocumentSessionToken)
    case characters(session: IOSDocumentSessionToken)
    case worldbuilding(session: IOSDocumentSessionToken)
    case references(session: IOSDocumentSessionToken)
    case settings(session: IOSDocumentSessionToken)
    case editor(
        session: IOSDocumentSessionToken,
        chapterID: ChapterID,
        episodeID: EpisodeID
    )

    var session: IOSDocumentSessionToken {
        switch self {
        case let .projectHome(session),
             let .projectInfo(session),
             let .writing(session),
             let .plot(session),
             let .characters(session),
             let .worldbuilding(session),
             let .references(session),
             let .settings(session),
             let .editor(session, _, _):
            session
        }
    }

    var documentID: IOSPrivateDocumentID {
        session.workingCopyID
    }
}

@MainActor
@Observable
final class IOSWorkspaceNavigationCoordinator {
    private(set) var path: [IOSWorkspaceRoute] = []
    private(set) var activeSession: IOSDocumentSessionToken?

    var activeDocumentID: IOSPrivateDocumentID? {
        activeSession?.workingCopyID
    }

    var activeEditorDeparture: IOSWorkspaceEditorDeparture? {
        Self.editorDeparture(in: path)
    }

    func showProjectHome(for session: IOSDocumentSessionToken) {
        activeSession = session
        path = [.projectHome(session: session)]
    }

    func showProjectInfo(for session: IOSDocumentSessionToken) {
        prepareProjectPath(for: session)
        path.append(.projectInfo(session: session))
    }

    func showWriting(for session: IOSDocumentSessionToken) {
        prepareProjectPath(for: session)
        path.append(.writing(session: session))
    }

    func showPlot(for session: IOSDocumentSessionToken) {
        prepareProjectPath(for: session)
        path.append(.plot(session: session))
    }

    func showCharacters(for session: IOSDocumentSessionToken) {
        prepareProjectPath(for: session)
        path.append(.characters(session: session))
    }

    func showWorldbuilding(for session: IOSDocumentSessionToken) {
        prepareProjectPath(for: session)
        path.append(.worldbuilding(session: session))
    }

    func showReferences(for session: IOSDocumentSessionToken) {
        prepareProjectPath(for: session)
        path.append(.references(session: session))
    }

    func showSettings(for session: IOSDocumentSessionToken) {
        prepareProjectPath(for: session)
        path.append(.settings(session: session))
    }

    func showEditor(
        for session: IOSDocumentSessionToken,
        chapterID: ChapterID,
        episodeID: EpisodeID
    ) {
        prepareProjectPath(for: session)
        if path.last != .writing(session: session) {
            path.append(.writing(session: session))
        }
        path.append(
            .editor(
                session: session,
                chapterID: chapterID,
                episodeID: episodeID
            )
        )
    }

    func documentDidChange(to session: IOSDocumentSessionToken) {
        let containsStaleRoute = path.contains { $0.session != session }
        guard activeSession != session || containsStaleRoute else { return }

        activeSession = session
        if !path.isEmpty {
            path = [.projectHome(session: session)]
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
        if let session = newPath.last?.session {
            activeSession = session
        }
        return true
    }

    private func prepareProjectPath(for session: IOSDocumentSessionToken) {
        activeSession = session
        let startsAtProjectHome = path.first == .projectHome(session: session)
        let containsOnlyCurrentSession = path.allSatisfy { $0.session == session }
        guard startsAtProjectHome, containsOnlyCurrentSession else {
            path = [.projectHome(session: session)]
            return
        }
    }

    private static func editorDeparture(
        in routes: [IOSWorkspaceRoute]
    ) -> IOSWorkspaceEditorDeparture? {
        for route in routes.reversed() {
            if case let .editor(session, chapterID, episodeID) = route {
                return IOSWorkspaceEditorDeparture(
                    session: session,
                    chapterID: chapterID,
                    episodeID: episodeID
                )
            }
        }
        for route in routes.reversed() {
            if case let .writing(session) = route {
                return IOSWorkspaceEditorDeparture(
                    session: session,
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
        guard store.currentDocumentSessionToken == departure.session else {
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
            guard store.currentDocumentSessionToken == departure.session else {
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
