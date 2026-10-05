import NovelCore
import NovelTextAnalysis
import NovelUI
import NovelWorkspace
import SwiftUI

public struct WorkSearchResults: View {
    public init(search: WorkSearchSession, onJump: @escaping (EpisodeTextMatches, WorkTextMatch) -> Void) {
        self.search = search
        self.onJump = onJump
    }

    @Bindable var search: WorkSearchSession
    let onJump: (EpisodeTextMatches, WorkTextMatch) -> Void

    public var body: some View {
        ForEach(chapterIDs, id: \.self) { chapterID in
            Section(search.results.first { $0.chapterID == chapterID }?.chapterTitle ?? "") {
                ForEach(search.results.filter { $0.chapterID == chapterID }) { result in
                    Text("\(result.episodeTitle) · \(result.matches.count)件")
                        .font(.headline)
                    ForEach(result.matches) { match in
                        HStack(alignment: .top, spacing: Spacing.small) {
                            Toggle("置換に含める", isOn: Binding(
                                get: { search.included(match, in: result) },
                                set: { search.setIncluded($0, match: match, in: result) }
                            ))
                            .labelsHidden()
                            #if os(macOS)
                                .toggleStyle(.checkbox)
                            #else
                                .toggleStyle(.switch)
                                .frame(minHeight: 44)
                            #endif
                                .accessibilityLabel("\(result.episodeTitle)、\(match.context)、置換に含める")
                            Button { onJump(result, match) } label: {
                                Text(match.context)
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                #if os(iOS)
                                    .frame(minHeight: 44)
                                #endif
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("話を開き、一致箇所を選択します")
                        }
                    }
                }
            }
        }
    }

    private var chapterIDs: [NovelCore.ChapterID] {
        var seen: Set<NovelCore.ChapterID> = []
        return search.results.compactMap { seen.insert($0.chapterID).inserted ? $0.chapterID : nil }
    }
}
