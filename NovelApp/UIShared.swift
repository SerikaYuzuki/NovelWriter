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

/// Workbenchのdetail chromeやOutline pane全体で共通利用するtranslucent surface。
struct WorkbenchGlassChromeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            // `.thinMaterial` は Reduce Transparency をOS標準の不透明表現へ
            // 自動でフォールバックするため、個別の外観分岐を持たない。
            .background(.thinMaterial)
    }
}

/// Outline系Listの選択・スクロール背景だけを整えるmodifier。materialは含めない。
struct WorkbenchOutlineListModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
    }
}

extension View {
    func workbenchGlassChromeStyle() -> some View {
        modifier(WorkbenchGlassChromeModifier())
    }

    func workbenchOutlineListStyle() -> some View {
        modifier(WorkbenchOutlineListModifier())
    }

    /// 単体のOutline List向け。Listスタイルとglass surfaceを1層で適用する。
    func workbenchGlassOutlineStyle() -> some View {
        workbenchOutlineListStyle()
            .workbenchGlassChromeStyle()
    }
}

struct CharacterAppearance: Identifiable {
    let chapterID: ChapterID
    let episodeID: EpisodeID
    let chapterTitle: String
    let query: String
    let range: NSRange

    var id: String {
        "\(chapterID.rawValue.uuidString)-\(episodeID.rawValue.uuidString)-\(query)-\(range.location)"
    }
}

enum CharacterAppearanceDetector {
    static func appearances(for character: NovelCore.Character, in document: NovelDocument) -> [CharacterAppearance] {
        let queries = appearanceQueries(for: character)
        guard !queries.isEmpty else { return [] }

        return document.chapters.flatMap { chapter in
            chapter.episodes.compactMap { episode in
                appearance(
                    for: character,
                    queries: queries,
                    in: episode,
                    chapterID: chapter.id,
                    chapterTitle: chapter.title
                )
            }
        }
    }

    static func appearances(
        for character: NovelCore.Character,
        in episode: Episode,
        chapterID: ChapterID,
        chapterTitle: String
    ) -> [CharacterAppearance] {
        let queries = appearanceQueries(for: character)
        guard !queries.isEmpty else { return [] }
        guard let appearance = appearance(
            for: character,
            queries: queries,
            in: episode,
            chapterID: chapterID,
            chapterTitle: chapterTitle
        ) else { return [] }
        return [appearance]
    }

    private static func appearance(
        for _: NovelCore.Character,
        queries: [String],
        in episode: Episode,
        chapterID: ChapterID,
        chapterTitle: String
    ) -> CharacterAppearance? {
        for query in queries {
            if let range = TextSearch.find(query: query, in: episode.content, from: 0, wraps: false) {
                return CharacterAppearance(
                    chapterID: chapterID,
                    episodeID: episode.id,
                    chapterTitle: chapterTitle,
                    query: query,
                    range: range
                )
            }
        }
        return nil
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
    var size: CGFloat = 8

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
            CharacterColorSwatch(colorHex: character.colorHex)
                .layoutPriority(1)

            VStack(alignment: .leading, spacing: 2) {
                Text(NovelDocument.normalizedCharacterName(character.name))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !character.kana.isEmpty {
                    Text(character.kana)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
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
                .foregroundStyle(flag.isResolved ? StyleToken.success : .secondary)

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
                    .monospacedDigit()
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
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
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
