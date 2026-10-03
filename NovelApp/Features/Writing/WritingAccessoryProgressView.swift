import AppKit
import NovelWritingProgress
import SwiftUI

struct WritingAccessoryProgressView: View {
    @Environment(AppState.self) private var appState
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let tracker = appState.writingProgress
            if let work = appState.currentSnapshotSyncV2WorkID?.rawValue {
                if let notice = tracker.notice, notice.workID == work {
                    Text(notice.message)
                } else {
                    let count = appState.selectedEpisodeID.map { tracker.episodeCount($0) } ?? 0
                    let today = tracker.days(for: work)[tracker.calendar.key(context.date)]?.added ?? 0
                    Text("話 \(count.formatted())字 · 今日 +\(today.formatted())字")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .transaction { $0.animation = nil }
        .onChange(of: appState.writingProgress.notice) { _, notice in
            guard let notice, notice.workID == appState.currentSnapshotSyncV2WorkID?.rawValue else { return }
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
                .announcement: notice.message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ])
        }
    }
}
