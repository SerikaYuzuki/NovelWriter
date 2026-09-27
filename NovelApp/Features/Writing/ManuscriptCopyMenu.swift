import NovelCore
import SwiftUI

/// Outlineから原稿を明示的にコピーする入口。
///
/// ここでは章／話のIDと表示時のdocument sessionだけを保持する。本文snapshotは
/// 保持せず、利用者が項目を実行した時点で`AppState`が現在の作品から再解決する。
enum ManuscriptCopyMenuTarget: Equatable {
    case episode(episodeID: EpisodeID, chapterID: ChapterID, session: DocumentSessionToken)
    case chapter(chapterID: ChapterID, session: DocumentSessionToken)

    var scopeDisplayName: String {
        switch self {
        case .episode:
            "この話"
        case .chapter:
            "この章"
        }
    }

    var menuLabel: String {
        "\(scopeDisplayName)をコピー"
    }
}

struct ManuscriptCopyMenu: View {
    let target: ManuscriptCopyMenuTarget

    var body: some View {
        ManuscriptCopyMenuContent(target: target)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(target.menuLabel)
            .accessibilityLabel(target.menuLabel)
    }
}

struct ManuscriptCopyContextMenu: View {
    let target: ManuscriptCopyMenuTarget

    var body: some View {
        ManuscriptCopyMenuContent(target: target)
    }
}

private struct ManuscriptCopyMenuContent: View {
    @Environment(AppState.self) private var appState
    let target: ManuscriptCopyMenuTarget

    var body: some View {
        Button(action: copy) {
            Label(target.menuLabel, systemImage: "doc.on.doc")
        }
        .disabled(!isCurrentSession)
    }

    private var isCurrentSession: Bool {
        switch target {
        case let .episode(_, _, session), let .chapter(_, session):
            session == appState.documentSessionToken
        }
    }

    private func copy() {
        switch target {
        case let .episode(episodeID, chapterID, session):
            appState.copyEpisodeManuscript(episodeID: episodeID, in: chapterID, expectedSession: session)
        case let .chapter(chapterID, session):
            appState.copyChapterManuscript(chapterID: chapterID, expectedSession: session)
        }
    }
}
