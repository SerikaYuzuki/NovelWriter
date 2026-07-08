import NovelCore
import SwiftUI

struct ChapterTitleField: View {
    let chapter: Chapter
    let onTitleChange: (String) -> Void
    let onCommit: () -> Void

    @State private var draftTitle: String
    @FocusState private var isFocused: Bool

    init(chapter: Chapter, onTitleChange: @escaping (String) -> Void, onCommit: @escaping () -> Void) {
        self.chapter = chapter
        self.onTitleChange = onTitleChange
        self.onCommit = onCommit
        _draftTitle = State(initialValue: chapter.title)
    }

    var body: some View {
        TextField("章タイトル", text: $draftTitle)
            .textFieldStyle(.plain)
            .focused($isFocused)
            .onChange(of: draftTitle) {
                onTitleChange(draftTitle)
            }
            .onChange(of: chapter.title) {
                if !isFocused {
                    draftTitle = chapter.title
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
        let committedTitle = normalizedTitle.isEmpty ? "無題の章" : normalizedTitle
        if draftTitle != committedTitle {
            draftTitle = committedTitle
            onTitleChange(committedTitle)
        }
        onCommit()
    }
}

struct ManuscriptStatusBar: View {
    let chapterCharacterCount: Int
    let totalCharacterCount: Int

    var body: some View {
        HStack(spacing: 16) {
            Text("章 \(chapterCharacterCount)字 / \(ManuscriptMetrics.manuscriptPages400(for: chapterCharacterCount))枚")
            Spacer()
            Text("全体 \(totalCharacterCount)字 / \(ManuscriptMetrics.manuscriptPages400(for: totalCharacterCount))枚")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

struct OperationMessage: Identifiable {
    let id = UUID()
    let title: String
    let body: String
}
