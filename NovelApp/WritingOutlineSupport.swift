import Foundation
import NovelCore
import SwiftUI

struct EpisodeDeletionRequest: Identifiable {
    let episode: Episode
    let chapterID: ChapterID
    let session: DocumentSessionToken

    var id: EpisodeID {
        episode.id
    }
}

struct OutlineDisclosureState: Equatable {
    private(set) var expandedChapterIDs: Set<ChapterID> = []
    private var knownChapterIDs: Set<ChapterID> = []

    mutating func reset(chapterIDs: [ChapterID], revealing chapterID: ChapterID?) {
        knownChapterIDs = Set(chapterIDs)
        expandedChapterIDs = []
        if let chapterID, knownChapterIDs.contains(chapterID) {
            expandedChapterIDs.insert(chapterID)
        }
    }

    mutating func synchronize(chapterIDs: [ChapterID], revealing chapterID: ChapterID?) {
        let currentChapterIDs = Set(chapterIDs)
        let addedChapterIDs = currentChapterIDs.subtracting(knownChapterIDs)
        expandedChapterIDs.formIntersection(currentChapterIDs)
        expandedChapterIDs.formUnion(addedChapterIDs)
        knownChapterIDs = currentChapterIDs

        if let chapterID, addedChapterIDs.contains(chapterID) {
            expandedChapterIDs.insert(chapterID)
        }
    }

    mutating func reveal(_ chapterID: ChapterID) {
        guard knownChapterIDs.contains(chapterID) else { return }
        expandedChapterIDs.insert(chapterID)
    }

    mutating func reveal(_ chapterIDs: [ChapterID]) {
        expandedChapterIDs.formUnion(Set(chapterIDs).intersection(knownChapterIDs))
    }

    mutating func setExpanded(_ isExpanded: Bool, for chapterID: ChapterID) {
        if isExpanded {
            expandedChapterIDs.insert(chapterID)
        } else {
            expandedChapterIDs.remove(chapterID)
        }
    }

    func isExpanded(_ chapterID: ChapterID) -> Bool {
        expandedChapterIDs.contains(chapterID)
    }
}

enum OutlineSaveStateVisibility {
    static func chapter(
        _ chapterID: ChapterID,
        selectedChapterID: ChapterID?,
        selectedEpisodeID: EpisodeID?
    ) -> Bool {
        selectedEpisodeID == nil && selectedChapterID == chapterID
    }

    static func episode(_ episodeID: EpisodeID, selectedEpisodeID: EpisodeID?) -> Bool {
        selectedEpisodeID == episodeID
    }
}

struct OutlineChapterRow: View {
    let chapter: Chapter
    let showsSaveState: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(displayTitle)
                .lineLimit(1)
                .truncationMode(.tail)

            HStack(spacing: 8) {
                Text("\(chapter.episodes.count)話")
                    .monospacedDigit()
                Text("\(characterCount)字")
                    .monospacedDigit()
                Spacer(minLength: 8)
                if showsSaveState {
                    SaveStateMetadataIcon(scopeLabel: "現在編集中の章")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var displayTitle: String {
        let trimmed = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "無題の章" : trimmed
    }

    private var characterCount: Int {
        chapter.episodes.reduce(0) {
            $0 + ManuscriptMetrics.countCharacters(in: $1.content)
        }
    }
}

struct OutlineEpisodeRow: View {
    @Environment(AppState.self) private var appState

    let episode: Episode
    let chapterID: ChapterID
    let showsSaveState: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            EpisodeTitleField(
                episode: episode,
                onTitleChange: { title in
                    appState.updateEpisodeTitle(title, for: episode.id, in: chapterID)
                },
                onCommit: {
                    appState.commitEpisodeTitleEditing()
                }
            )
            .lineLimit(1)
            .truncationMode(.tail)

            HStack(spacing: 8) {
                Text("\(characterCount)字")
                    .monospacedDigit()
                Spacer(minLength: 8)
                if showsSaveState {
                    SaveStateMetadataIcon(scopeLabel: "現在編集中の話")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var characterCount: Int {
        ManuscriptMetrics.countCharacters(in: episode.content)
    }
}

struct EpisodeOutlineContextMenu: View {
    @Environment(AppState.self) private var appState

    let request: EpisodeDeletionRequest
    let onDelete: () -> Void

    var body: some View {
        Button {
            guard isCurrentSession else { return }
            appState.selectEpisode(request.episode.id, in: request.chapterID)
            NotificationCenter.default.post(name: .presentChapterMemo, object: nil)
        } label: {
            Label("話メモ", systemImage: "note.text")
        }
        .disabled(!isCurrentSession)

        Menu {
            if otherChapters.isEmpty {
                Text("移動先の章がありません")
            } else {
                ForEach(otherChapters) { destination in
                    Button(destination.title) {
                        guard isCurrentSession else { return }
                        _ = appState.moveEpisode(
                            id: request.episode.id,
                            from: request.chapterID,
                            to: destination.id
                        )
                    }
                }
            }
        } label: {
            Label("別の章へ移動", systemImage: "arrow.right")
        }
        .disabled(!isCurrentSession)

        Button("話を削除", systemImage: "trash", role: .destructive) {
            onDelete()
        }
        .disabled(!isCurrentSession)
    }

    private var otherChapters: [Chapter] {
        guard isCurrentSession else { return [] }
        return appState.document.chapters.filter { $0.id != request.chapterID }
    }

    private var isCurrentSession: Bool {
        request.session == appState.documentSessionToken
    }
}

struct ChapterOutlineContextMenu: View {
    @Environment(AppState.self) private var appState

    let chapterItem: SessionBoundValue<Chapter>
    let onRename: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button("章タイトルを編集", systemImage: "pencil", action: onRename)
            .disabled(!isCurrentSession)

        Button {
            guard isCurrentSession else { return }
            onReveal()
            appState.addEpisode(to: chapter.id)
        } label: {
            Label("この章に話を追加", systemImage: "square.and.pencil")
        }
        .disabled(!isCurrentSession)

        Button {
            guard isCurrentSession else { return }
            appState.selectChapter(chapter.id)
            NotificationCenter.default.post(name: .presentChapterMemo, object: nil)
        } label: {
            Label("話メモ", systemImage: "note.text")
        }
        .disabled(!isCurrentSession || chapter.episodes.isEmpty)

        Menu {
            ChapterContextMenuContent(
                appState: appState,
                chapterID: chapter.id,
                onOpenCharacter: { characterID in
                    guard isCurrentSession else { return }
                    appState.selectCharacter(characterID)
                    appState.selectProjectSection(.characters)
                },
                onOpenPlotCard: { cardID in
                    guard isCurrentSession else { return }
                    appState.selectPlotCard(cardID)
                    appState.selectProjectSection(.plot)
                }
            )
        } label: {
            Label("この章", systemImage: "doc.text.magnifyingglass")
        }
        .disabled(!isCurrentSession)

        Button("章を削除", systemImage: "trash", role: .destructive, action: onDelete)
            .disabled(!isCurrentSession || appState.document.chapters.count <= 1)
    }

    private var chapter: Chapter {
        chapterItem.value
    }

    private var isCurrentSession: Bool {
        chapterItem.session == appState.documentSessionToken
    }
}

private struct SaveStateMetadataIcon: View {
    @Environment(AppState.self) private var appState

    let scopeLabel: String

    var body: some View {
        Image(systemName: appState.saveState.systemImage)
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .help("\(scopeLabel)・作品の保存状態: \(appState.saveState.label)")
            .accessibilityLabel("\(scopeLabel)の作品保存状態、\(appState.saveState.label)")
    }
}

private struct EpisodeTitleField: View {
    let episode: Episode
    let onTitleChange: (String) -> Void
    let onCommit: () -> Void

    @State private var draftTitle: String
    @FocusState private var isFocused: Bool

    init(episode: Episode, onTitleChange: @escaping (String) -> Void, onCommit: @escaping () -> Void) {
        self.episode = episode
        self.onTitleChange = onTitleChange
        self.onCommit = onCommit
        _draftTitle = State(initialValue: episode.title)
    }

    var body: some View {
        TextField("話タイトル", text: $draftTitle)
            .textFieldStyle(.plain)
            .focused($isFocused)
            .onChange(of: draftTitle) {
                onTitleChange(draftTitle)
            }
            .onChange(of: episode.title) {
                if !isFocused {
                    draftTitle = episode.title
                }
            }
            .onChange(of: isFocused) {
                if !isFocused {
                    commit()
                }
            }
            .onSubmit {
                commit()
            }
    }

    private func commit() {
        let normalizedTitle = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let committedTitle = normalizedTitle.isEmpty ? Episode.defaultTitle : normalizedTitle
        if draftTitle != committedTitle {
            draftTitle = committedTitle
            onTitleChange(committedTitle)
        }
        onCommit()
    }
}
