import Foundation
import NovelCore
import SwiftUI

/// Presentation-only, bounded memory cache. No persistence or save-path hooks.
public final class ManuscriptCountCache: @unchecked Sendable {
    public static let shared = ManuscriptCountCache()
    private let lock = NSLock()
    private var entries: [EpisodeID: (content: String, count: Int)] = [:]
    private var notes: [WorldNoteID: (content: String, count: Int)] = [:]
    private var chapters: [ChapterID: (episodes: [Episode], count: Int)] = [:]
    public init() {}

    public func count(_ episode: Episode) -> Int {
        lock.lock()
        defer { lock.unlock() }
        if let entry = entries[episode.id], entry.content == episode.content {
            return entry.count
        }
        let count = ManuscriptMetrics.countCharacters(in: episode.content)
        if entries.count >= 512 {
            entries.removeAll(keepingCapacity: true)
        }
        entries[episode.id] = (episode.content, count)
        return count
    }

    public func count(_ chapter: Chapter) -> Int {
        lock.lock()
        let cached = chapters[chapter.id]
        lock.unlock()
        if let cached, cached.episodes == chapter.episodes {
            return cached.count
        }
        let total = chapter.episodes.reduce(0) { $0 + count($1) }
        lock.lock()
        if chapters.count >= 512 {
            chapters.removeAll(keepingCapacity: true)
        }
        chapters[chapter.id] = (chapter.episodes, total)
        lock.unlock()
        return total
    }

    public func count(_ note: WorldNote) -> Int {
        lock.lock()
        defer { lock.unlock() }
        if let cached = notes[note.id], cached.content == note.content {
            return cached.count
        }
        let count = ManuscriptMetrics.countCharacters(in: note.content)
        if notes.count >= 512 {
            notes.removeAll(keepingCapacity: true)
        }
        notes[note.id] = (note.content, count)
        return count
    }

    public func count(_ document: NovelDocument) -> Int {
        document.chapters.reduce(0) { $0 + count($1) }
    }
}

public struct GeneratedCover: View {
    private let title: String
    public init(title: String) {
        self.title = title
    }

    public var body: some View {
        ZStack(alignment: .leading) {
            FuminiwaColor.paper.color
            FuminiwaColor.accent.color.frame(width: 12)
            Text(CoverInitial.character(in: title))
                .font(FuminiwaType.coverInitial)
                .foregroundStyle(FuminiwaColor.textPrimary.color)
                .frame(maxWidth: .infinity)
        }
        .frame(width: 96, height: 144)
        .clipShape(RoundedRectangle(cornerRadius: Radius.cover, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.cover, style: .continuous)
            .strokeBorder(FuminiwaColor.separator.color, lineWidth: 0.5))
        .coverShadow()
        .accessibilityHidden(true)
    }
}

public struct WorkInfoSummary: View {
    private let document: NovelDocument
    private let coverData: Data?
    private let synopsis: String?
    @State private var count = 0
    @State private var episodeCount = 0
    private let showsCover: Bool
    public init(document: NovelDocument, coverData: Data? = nil, showsCover: Bool = true, synopsis: String? = nil) {
        self.document = document
        self.coverData = coverData
        self.synopsis = synopsis
        self.showsCover = showsCover
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.outer) { cover; title }
                VStack(alignment: .leading, spacing: Spacing.group) { cover; title }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: Spacing.small) {
                stat("文字数", value: count)
                stat("400字詰め枚数", value: ManuscriptMetrics.manuscriptPages400(for: count))
                stat("章", value: document.chapters.count)
                stat("話", value: episodeCount)
            }
        }
        .onChange(of: document.chapters, initial: true) { _, chapters in
            count = ManuscriptCountCache.shared.count(document)
            episodeCount = chapters.reduce(0) { $0 + $1.episodes.count }
        }
    }

    @ViewBuilder
    private var cover: some View {
        if showsCover {
            ThumbnailImage(data: coverData, kind: .work, title: document.title, size: 96).accessibilityHidden(true)
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(document.title.isEmpty ? "名称未設定の作品" : document.title)
                .font(FuminiwaType.workTitle)
                .foregroundStyle(FuminiwaColor.textPrimary.color)
                .fixedSize(horizontal: false, vertical: true)
            if let synopsis, !synopsis.isEmpty {
                Text(synopsis).font(.body).foregroundStyle(FuminiwaColor.textSecondary.color).lineLimit(3)
            }
        }
    }

    private func stat(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(title).font(.caption).foregroundStyle(FuminiwaColor.textSecondary.color)
            Text(value, format: .number).font(.title2).monospacedDigit()
                .foregroundStyle(FuminiwaColor.textPrimary.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.medium)
        .background(FuminiwaColor.surface.color, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

public enum CoverInitial {
    public static func character(in title: String) -> String {
        let ignored = CharacterSet.decimalDigits.union(.whitespacesAndNewlines).union(.punctuationCharacters).union(.symbols)
        return title.first(where: { character in
            character.unicodeScalars.contains { !ignored.contains($0) }
        }).map(String.init) ?? "文"
    }
}
