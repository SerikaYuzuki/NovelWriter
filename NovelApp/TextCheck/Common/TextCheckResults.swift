import NovelCore
import NovelTextAnalysis
import SwiftUI

struct TextCheckResults: View {
    @Bindable var session: TextCheckSession
    let onJump: (TextCheckOccurrence) -> Void
    let onReplace: (TextCheckIssue) -> Void

    var body: some View {
        let visible = session.visibleIssues
        ForEach(TextCheckRule.allCases, id: \.self) { rule in
            let issues = visible.filter { $0.rule == rule }
            if !issues.isEmpty {
                TextCheckRuleResults(session: session, rule: rule, issues: issues, onJump: onJump, onReplace: onReplace)
            }
        }
    }
}

private struct TextCheckRuleResults: View {
    @Bindable var session: TextCheckSession
    let rule: TextCheckRule
    let issues: [TextCheckIssue]
    let onJump: (TextCheckOccurrence) -> Void
    let onReplace: (TextCheckIssue) -> Void

    private var episodeIDs: [EpisodeID] {
        let present = Set(issues.flatMap(\.occurrences).map(\.result.episodeID))
        return session.orderedEpisodeIDs.filter { present.contains($0) }
    }

    var body: some View {
        Section("\(rule.title) · \(issues.reduce(0) { $0 + $1.occurrences.count })件") {
            ForEach(issues.filter { !$0.variants.isEmpty || $0.rule == .characterTypo }) { issue in
                VStack(alignment: .leading) {
                    Text(issue.title).font(.headline)
                    // 同数では多数派を決めず、置換を提案しない。
                    if issue.replacement != nil {
                        Button { onReplace(issue) } label: { Text("置換…").frame(minHeight: 44) }
                            .accessibilityHint("少数派を検索欄、多数派を置換欄に入れて作品全体検索を開きます")
                    }
                    Button { session.ignore(issue) } label: { Text("この組を無視").frame(minHeight: 44) }
                }
            }
            ForEach(episodeIDs, id: \.self) { episodeID in
                let entries = issues.flatMap { issue in issue.occurrences.filter { $0.result.episodeID == episodeID }.map { TextCheckEntry(issue: issue, occurrence: $0) } }
                    .sorted { $0.occurrence.match.range.location < $1.occurrence.match.range.location }
                if let first = entries.first {
                    Text("\(first.occurrence.result.chapterTitle) / \(first.occurrence.result.episodeTitle) · \(entries.count)件")
                        .font(.headline)
                    ForEach(entries) { entry in
                        VStack(alignment: .leading) {
                            if !entry.issue.variants.isEmpty || entry.issue.rule == .characterTypo {
                                Text(entry.issue.title).font(.caption).foregroundStyle(.secondary)
                            }
                            Button { onJump(entry.occurrence) } label: {
                                Text(entry.occurrence.match.context)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(entry.occurrence.result.episodeTitle)、\(entry.issue.title)、\(entry.occurrence.match.context)")
                            .accessibilityHint("話を開き、指摘範囲を選択します")
                            Button { session.ignore(entry.issue, occurrence: entry.occurrence) } label: {
                                Text("無視").frame(minHeight: 44)
                            }
                            .accessibilityLabel("この指摘を無視")
                        }
                    }
                }
            }
        }
        .buttonStyle(.borderless)
    }
}

private struct TextCheckEntry: Identifiable {
    let issue: TextCheckIssue
    let occurrence: TextCheckOccurrence
    var id: String {
        issue.id + ":" + occurrence.id
    }
}
