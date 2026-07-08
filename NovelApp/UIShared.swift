import AppKit
import EditorKit
import Foundation
import NovelCore
import NovelUI
import SwiftUI

struct OperationMessage: Identifiable {
    let id = UUID()
    let title: String
    let body: String
}

struct CharacterAppearance: Identifiable {
    let chapterID: ChapterID
    let chapterTitle: String
    let query: String
    let range: NSRange

    var id: String {
        "\(chapterID.rawValue.uuidString)-\(query)-\(range.location)"
    }
}

enum CharacterAppearanceDetector {
    static func appearances(for character: NovelCore.Character, in document: NovelDocument) -> [CharacterAppearance] {
        let queries = appearanceQueries(for: character)
        guard !queries.isEmpty else { return [] }

        return document.chapters.compactMap { chapter in
            for query in queries {
                if let range = TextSearch.find(query: query, in: chapter.content, from: 0, wraps: false) {
                    return CharacterAppearance(
                        chapterID: chapter.id,
                        chapterTitle: chapter.title,
                        query: query,
                        range: range
                    )
                }
            }
            return nil
        }
    }

    private static func appearanceQueries(for character: NovelCore.Character) -> [String] {
        var seen: Set<String> = []
        let candidates = [
            NovelDocument.normalizedCharacterName(character.name),
            character.kana.trimmingCharacters(in: .whitespacesAndNewlines)
        ]

        return candidates.compactMap { candidate in
            guard !candidate.isEmpty, !seen.contains(candidate) else { return nil }
            seen.insert(candidate)
            return candidate
        }
    }
}

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

struct CharacterColorSwatch: View {
    let colorHex: String?
    var size: CGFloat = 10

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay {
                Circle()
                    .stroke(.secondary.opacity(0.35), lineWidth: 1)
            }
    }

    private var color: Color {
        guard let colorHex, let color = Color(hex: colorHex) else {
            return .clear
        }
        return color
    }
}

struct CharacterRow: View {
    let character: NovelCore.Character

    var body: some View {
        HStack(spacing: 8) {
            CharacterColorSwatch(colorHex: character.colorHex, size: 11)

            VStack(alignment: .leading, spacing: 2) {
                Text(NovelDocument.normalizedCharacterName(character.name))
                    .lineLimit(1)
                if !character.kana.isEmpty {
                    Text(character.kana)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

struct PlotCardRow: View {
    let card: PlotCard
    let chapterTitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(NovelDocument.normalizedPlotCardTitle(card.title))
                .lineLimit(1)
            if let chapterTitle {
                Text(chapterTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct FlagRow: View {
    let flag: Flag
    let plantedTitle: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: flag.isResolved ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(flag.isResolved ? .green : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(NovelDocument.normalizedFlagTitle(flag.title))
                    .lineLimit(1)
                if let plantedTitle {
                    Text(plantedTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

struct AttachmentRow: View {
    let attachment: Attachment

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc")
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.fileName)
                    .lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: attachment.byteCount, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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

extension NSColor {
    var hexString: String? {
        guard let rgb = usingColorSpace(.sRGB) else { return nil }
        let red = Int(round(rgb.redComponent * 255))
        let green = Int(round(rgb.greenComponent * 255))
        let blue = Int(round(rgb.blueComponent * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
