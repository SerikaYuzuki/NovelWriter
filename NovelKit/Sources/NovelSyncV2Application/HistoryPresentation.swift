import Foundation
import NovelSyncV2

/// Calendar and clock are injected so day boundaries follow the reader's timezone.
public struct HistoryPresentation {
    public struct Day: Identifiable {
        public var id: Date
        public var title: String
        public var runs: [Run]
    }

    public struct Run: Identifiable {
        public var items: [SyncV2HistoryItem]
        public var id: UUID {
            items[0].occurrenceID
        }

        public var isCollapsedAutosave: Bool {
            items.count > 1
        }
    }

    public var calendar: Calendar
    public var now: Date

    public init(calendar: Calendar = .current, now: Date = Date()) {
        self.calendar = calendar
        self.now = now
    }

    public func format(_ date: Date, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    public func time(_ date: Date) -> String {
        format(date, pattern: "HH:mm")
    }

    public func versionDate(_ date: Date) -> String {
        let day = dayTitle(date)
        if day == "今日" || day == "昨日" {
            return day + " " + time(date)
        }
        return format(date, pattern: "M月d日 HH:mm")
    }

    public func fullDate(_ date: Date) -> String {
        format(date, pattern: "yyyy年M月d日 HH:mm")
    }

    public func label(_ item: SyncV2HistoryItem) -> String {
        fullDate(item.createdAt) + "・" + subtitle(item)
    }

    public func predecessor(of item: SyncV2HistoryItem, in items: [SyncV2HistoryItem]) -> SnapshotID? {
        let ordered = days(items).flatMap(\.runs).flatMap(\.items)
        guard let index = ordered.firstIndex(where: { $0.occurrenceID == item.occurrenceID && $0.source == item.source }),
              index + 1 < ordered.count else { return nil }
        return ordered[index + 1].snapshotID
    }

    /// Ordinary remote adoption alone is not proof of a rejected conflict branch.
    public func isUnselectedConflictVersion(_ item: SyncV2HistoryItem, in items: [SyncV2HistoryItem]) -> Bool {
        guard let generation = item.localGeneration else { return false }
        if item.reason == "conflictRemote" {
            return items.contains { $0.reason == "conflictResolution" && $0.localGeneration == generation + 1 }
        }
        guard item.reason == "conflictLocal" || item.reason == "preRemoteAdoption" else { return false }
        let local = items.contains {
            $0.reason == "conflictLocal" && $0.localGeneration == generation && $0.snapshotID == item.snapshotID
        }
        let preserved = items.contains {
            $0.reason == "preRemoteAdoption" && $0.localGeneration == generation && $0.snapshotID == item.snapshotID
        }
        return local && preserved
    }

    public func subtitle(_ item: SyncV2HistoryItem) -> String {
        item.displayReason + (item.pinned ? "・保持" : "")
    }

    public func dayTitle(_ date: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return "今日"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨日"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return format(date, pattern: sameYear ? "M月d日（E）" : "yyyy年M月d日（E）")
    }

    public func autosaveLabel(_ run: Run) -> String {
        let oldest = run.items[run.items.count - 1].createdAt
        let newest = run.items[0].createdAt
        let retained = run.items.contains(where: \.pinned) ? "・保持あり" : ""
        return "自動保存 \(run.items.count)件 · \(time(oldest))〜\(time(newest))" + retained
    }

    public func days(_ items: [SyncV2HistoryItem]) -> [Day] {
        let sorted = items.enumerated().sorted {
            $0.element.createdAt == $1.element.createdAt ? $0.offset < $1.offset : $0.element.createdAt > $1.element
                .createdAt
        }.map(\.element)
        var days: [Day] = []
        for item in sorted {
            let date = calendar.startOfDay(for: item.createdAt)
            if days.last?.id != date {
                days.append(Day(id: date, title: dayTitle(date), runs: []))
            }
            let day = days.count - 1
            if item.isAutosave, let last = days[day].runs.last, last.items[0].isAutosave {
                days[day].runs[days[day].runs.count - 1].items.append(item)
            } else {
                days[day].runs.append(Run(items: [item]))
            }
        }
        return days
    }
}

public extension SyncV2HistoryItem {
    var isAutosave: Bool {
        reason == "autosave" || reason == "autosaveLeaf"
    }

    var historySymbol: String {
        switch reason {
        case "explicit": "bookmark"
        case "restore": "arrow.uturn.backward"
        case "conflictResolution": "arrow.triangle.branch"
        case "keepBoth": "doc.on.doc"
        case "preRestore", "preRemoteAdoption": "shield.lefthalf.filled"
        case "autosave", "autosaveLeaf": "clock"
        default: "doc.text"
        }
    }
}
