import NovelCore
import SwiftUI

/// Outlineから外部AIチャット用のプロンプトを明示的にコピーする入口。
///
/// ここでは章／話のIDと表示時のdocument sessionだけを保持する。本文snapshotは
/// 保持せず、利用者が項目を実行した時点で`AppState`が現在の作品から再解決する。
enum AIClipboardPromptMenuTarget: Equatable {
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
        "\(scopeDisplayName)のAIチャット用プロンプト"
    }
}

struct AIClipboardPromptMenu: View {
    @Environment(AppState.self) private var appState

    let target: AIClipboardPromptMenuTarget

    var body: some View {
        Menu {
            AIClipboardPromptMenuContent(target: target)
        } label: {
            Label(target.menuLabel, systemImage: "sparkles")
        }
        .labelStyle(.iconOnly)
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .help("\(target.scopeDisplayName)の校正／アドバイス用プロンプトをシステムクリップボードへコピー")
        .accessibilityLabel(target.menuLabel)
        .accessibilityHint("\(target.scopeDisplayName)の校正またはアドバイス用プロンプトを選びます")
        .disabled(!isCurrentSession)
    }

    private var isCurrentSession: Bool {
        switch target {
        case let .episode(episodeID: _, chapterID: _, session),
             let .chapter(chapterID: _, session):
            session == appState.documentSessionToken
        }
    }
}

struct AIClipboardPromptContextMenu: View {
    let target: AIClipboardPromptMenuTarget

    var body: some View {
        Menu {
            AIClipboardPromptMenuContent(target: target)
        } label: {
            Label(target.menuLabel, systemImage: "sparkles")
        }
    }
}

private struct AIClipboardPromptMenuContent: View {
    @Environment(AppState.self) private var appState

    let target: AIClipboardPromptMenuTarget

    var body: some View {
        Button {
            copy(purpose: .proofreading)
        } label: {
            Label("校正用プロンプトをコピー", systemImage: "checkmark.bubble")
        }
        .accessibilityLabel("\(target.scopeDisplayName)の校正用プロンプトをコピー")
        .disabled(!isCurrentSession)

        Button {
            copy(purpose: .advice)
        } label: {
            Label("アドバイス用プロンプトをコピー", systemImage: "lightbulb")
        }
        .accessibilityLabel("\(target.scopeDisplayName)のアドバイス用プロンプトをコピー")
        .disabled(!isCurrentSession)
    }

    private var isCurrentSession: Bool {
        switch target {
        case let .episode(episodeID: _, chapterID: _, session),
             let .chapter(chapterID: _, session):
            session == appState.documentSessionToken
        }
    }

    private func copy(purpose: AIClipboardPromptPurpose) {
        switch target {
        case let .episode(episodeID, chapterID, session):
            appState.copyEpisodeAIChatPrompt(
                purpose: purpose,
                episodeID: episodeID,
                in: chapterID,
                expectedSession: session
            )
        case let .chapter(chapterID, session):
            appState.copyChapterAIChatPrompt(
                purpose: purpose,
                chapterID: chapterID,
                expectedSession: session
            )
        }
    }
}
