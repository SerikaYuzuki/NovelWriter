import NovelCore
import SwiftUI

public struct AssistantScopeSelector: View {
    public init(chapters: [Chapter], currentID: EpisodeID?, scope: Binding<AssistantScope>) {
        self.chapters = chapters
        self.currentID = currentID
        _scope = scope
    }

    let chapters: [Chapter]
    let currentID: EpisodeID?
    @Binding var scope: AssistantScope
    @State private var contentHeight: CGFloat = 220

    private var selectedIDs: Set<EpisodeID> {
        scope.selectedEpisodeIDs(chapters: chapters, currentID: currentID)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("送る範囲").font(.subheadline.bold())
                Spacer()
                Text("\(selectedIDs.count)話を選択").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("現在の話だけ") { scope = .current }
                    .disabled(currentID == nil)
                Button("選択解除") { scope = .episodes([]) }
                    .disabled(selectedIDs.isEmpty)
            }.font(.caption)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(chapters) { chapter in
                        let ids = Set(chapter.episodes.map(\.id))
                        let count = selectedIDs.intersection(ids).count
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle(isOn: selection(ids)) {
                                HStack {
                                    Text(chapter.title).font(.subheadline.bold())
                                    Spacer()
                                    Text("\(count)/\(ids.count)話").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(AssistantCheckboxStyle(isMixed: count > 0 && count < ids.count))
                            .disabled(ids.isEmpty)
                            .accessibilityHint("章内の話をまとめて選択または解除します")
                            .accessibilityIdentifier("assistant.scope.chapter.\(chapter.id)")
                            ForEach(chapter.episodes) { episode in
                                Toggle(isOn: selection([episode.id])) {
                                    HStack {
                                        Text(episode.title).lineLimit(2)
                                        if episode.id == currentID {
                                            Text("現在の話").font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .toggleStyle(AssistantCheckboxStyle())
                                .padding(.leading, 22)
                                .accessibilityIdentifier("assistant.scope.episode.\(episode.id)")
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: ScopeContentHeight.self, value: geometry.size.height)
                    }
                }
            }
            .frame(height: min(220, contentHeight))
            .onPreferenceChange(ScopeContentHeight.self) { contentHeight = $0 }
        }
        .accessibilityIdentifier("assistant.scope.selector")
    }

    private func selection(_ ids: Set<EpisodeID>) -> Binding<Bool> {
        Binding(get: { !ids.isEmpty && selectedIDs.isSuperset(of: ids) }, set: {
            scope.setSelected(ids, to: $0, chapters: chapters, currentID: currentID)
        })
    }
}

private struct ScopeContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct AssistantCheckboxStyle: ToggleStyle {
    var isMixed = false

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: isMixed ? "minus.square.fill"
                    : (configuration.isOn ? "checkmark.square.fill" : "square"))
                    .foregroundStyle(configuration.isOn || isMixed ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
                configuration.label
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            #if os(iOS)
                .frame(minHeight: 44)
            #else
                .frame(minHeight: 22)
            #endif
        }
        .buttonStyle(.plain)
        .accessibilityValue(isMixed ? "一部選択" : (configuration.isOn ? "選択済み" : "未選択"))
    }
}
