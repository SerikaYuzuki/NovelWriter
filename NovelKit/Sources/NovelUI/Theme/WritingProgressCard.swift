import NovelWritingProgress
import SwiftUI

public struct WritingProgressCard: View {
    private let tracker: WritingProgressTracker
    @State private var showsGoal = false
    @State private var selectedDay: String?
    public init(tracker: WritingProgressTracker) {
        self.tracker = tracker
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let work = tracker.workID {
                card(work: work, now: context.date)
            }
        }
        .onAppear { tracker.publishSnapshot() }
        .transaction { $0.animation = nil }
        .sheet(isPresented: $showsGoal) {
            if let work = tracker.workID {
                WritingGoalSheet(goal: tracker.goal, calendar: tracker.calendar) { value in
                    tracker.setGoal(value, for: work)
                }
            }
        }
        .onChange(of: tracker.workID) { _, _ in showsGoal = false; selectedDay = nil }
    }

    private func card(work: UUID, now: Date) -> some View {
        let days = tracker.days(for: work)
        let today = days[tracker.calendar.key(now)] ?? WritingDay()
        return VStack(alignment: .leading, spacing: Spacing.group) {
            Text("進み具合").font(FuminiwaType.groupTitle)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.group) { todayText(today); streakText(days, now: now) }
                VStack(alignment: .leading, spacing: Spacing.small) { todayText(today); streakText(days, now: now) }
            }
            WritingHeatmap(days: days, calendar: tracker.calendar, now: now, selectedDay: $selectedDay)
            #if os(iOS)
            Text(dayDescription(selectedDay ?? tracker.calendar.key(now), days: days))
                .font(.caption).foregroundStyle(FuminiwaColor.textSecondary.color)
            #endif
            Divider()
            if let goal = tracker.goal {
                goalView(goal, now: now)
            }
            Button(tracker.goal == nil ? "目標を設定…" : "目標を変更…") { showsGoal = true }
                .buttonStyle(.bordered)
                .frame(minHeight: minimumTapHeight)
            milestoneView(work: work)
            if tracker.persistenceFailed {
                Label(tracker.persistenceRetryStopped ? "進み具合を端末に記録できていません。" : "進み具合を端末に記録できていません。再試行します。", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(FuminiwaColor.warning.color)
            }
        }
        .monospacedDigit()
        .foregroundStyle(FuminiwaColor.textPrimary.color)
        .padding(Spacing.group)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FuminiwaColor.surface.color, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(
            FuminiwaColor.separator.color,
            lineWidth: 0.5
        ))
    }

    private var minimumTapHeight: CGFloat {
        #if os(iOS)
        44
        #else
        0
        #endif
    }

    private func todayText(_ day: WritingDay) -> some View {
        VStack(alignment: .leading, spacing: Spacing.extraSmall) {
            Text("今日 +\(day.added.formatted())字").font(.title2)
            Text("純増 \(day.net >= 0 ? "+" : "")\(day.net.formatted())字")
                .font(.caption).foregroundStyle(FuminiwaColor.textSecondary.color)
        }.accessibilityElement(children: .combine)
    }

    private func streakText(_ days: [String: WritingDay], now: Date) -> some View {
        let streak = tracker.calendar.streak(days, now: now)
        return VStack(alignment: .leading, spacing: Spacing.extraSmall) {
            Text("継続 \(streak)日 · 今週 \(tracker.calendar.thisWeek(days, now: now))日")
            if streak > 0 {
                Text("1日休んでも続きます").font(.caption).foregroundStyle(FuminiwaColor.textSecondary.color)
            }
        }.accessibilityElement(children: .combine)
    }

    private func dayDescription(_ key: String, days: [String: WritingDay]) -> String {
        let date = tracker.calendar.date(key) ?? Date()
        return "\(date.formatted(.dateTime.month().day())) +\((days[key]?.added ?? 0).formatted())字"
    }

    private func goalView(_ goal: WritingGoal, now: Date) -> some View {
        let status = goal.status(current: tracker.total, now: now, calendar: tracker.calendar)
        return VStack(alignment: .leading, spacing: Spacing.small) {
            Text("\(tracker.total.formatted()) / \(goal.characters.formatted())字（\(Int(status.fraction * 100))%）")
            ProgressView(value: status.fraction).tint(FuminiwaColor.leaf.color)
                .accessibilityLabel("目標字数の進捗")
            if status.achieved {
                Label("目標を達成しました", systemImage: "checkmark.circle").foregroundStyle(FuminiwaColor.leaf.color)
            } else {
                Text("残り \(status.remaining.formatted())字")
                if status.overdue {
                    Label("締切を過ぎています", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(FuminiwaColor.warning.color)
                } else if let days = status.daysRemaining, let required = status.dailyRequired {
                    Text("あと\(days)日（今日を含む） · 1日あたり\(required.formatted())字")
                        .font(.caption).foregroundStyle(FuminiwaColor.textSecondary.color)
                }
            }
            if let deadline = goal.deadline, let date = tracker.calendar.date(deadline) {
                Text("締切 \(date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(FuminiwaColor.textSecondary.color)
            }
        }
    }

    private func milestoneView(work: UUID) -> some View {
        let milestones = tracker.milestones(for: work)
        let latest = milestones.filter { $0.reachedAt != nil }
            .max { ($0.reachedAt ?? .distantPast) < ($1.reachedAt ?? .distantPast) }
        let next = WritingThresholds.candidates(through: tracker.total, goal: tracker.goal?.characters)
            .first { $0 > tracker.total }
        return VStack(alignment: .leading, spacing: Spacing.small) {
            if let latest {
                Text("最近の到達: \(milestoneDescription(latest))").font(.caption)
            }
            if let next {
                Text("次は\(WritingThresholds.label(next))まで あと\((next - tracker.total).formatted())字")
            }
            if !milestones.isEmpty {
                DisclosureGroup("到達済み（\(milestones.count)）") {
                    ForEach(milestones) { value in
                        Text(milestoneDescription(value)).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func milestoneDescription(_ value: WritingMilestone) -> String {
        let label = WritingThresholds.label(value.threshold) + (value.threshold == 100_000 ? "（文庫1冊の目安）" : "")
        return label + " · " + (value.reachedAt.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "以前に到達")
    }
}

private struct WritingHeatmap: View {
    let days: [String: WritingDay]
    let calendar: WritingCalendar
    let now: Date
    @Binding var selectedDay: String?
    @State private var displayedWeeks = 16
    @State private var dates: [HeatmapDate] = []

    private struct HeatmapDate: Identifiable {
        let date: Date
        let id: String
        let label: String
    }

    private func prepareDates(endingAt weekStart: Date) {
        var date = calendar.offset(weekStart, days: -(maximumWeeks - 1) * 7)
        dates = (0 ..< maximumWeeks * 7).map { _ in
            let value = HeatmapDate(date: date, id: calendar.key(date), label: date.formatted(.dateTime.month().day()))
            date = calendar.offset(date, days: 1)
            return value
        }
    }

    private var maximumWeeks: Int {
        #if os(macOS)
        26
        #else
        16
        #endif
    }

    var body: some View {
        GeometryReader { geometry in
            let weeks = max(
                1,
                min(maximumWeeks, Int(max(0, geometry.size.width - Spacing.large) / (Spacing.medium + Spacing.xxs)))
            )
            let weekStart = calendar.calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.calendar
                .startOfDay(for: now)
            let visible = Array(dates.suffix(weeks * 7))
            let values = visible.map { days[$0.id]?.added ?? 0 }
            let weekdays = calendar.calendar.veryShortWeekdaySymbols
            HStack(alignment: .top, spacing: Spacing.extraSmall) {
                VStack(spacing: Spacing.xxs) {
                    ForEach(0 ..< 7, id: \.self) { row in
                        Text(weekdays[(calendar.calendar.firstWeekday - 1 + row) % 7])
                            .font(FuminiwaType.metadata).dynamicTypeSize(...DynamicTypeSize.large)
                            .frame(width: Spacing.outer, height: Spacing.medium)
                    }
                }
                HStack(spacing: Spacing.xxs) {
                    ForEach(0 ..< weeks, id: \.self) { week in
                        VStack(spacing: Spacing.xxs) {
                            ForEach(0 ..< 7, id: \.self) { row in
                                let index = week * 7 + row
                                if index < visible.count {
                                    cell(visible[index], value: values[index])
                                }
                            }
                        }
                    }
                }
            }
            .onChange(of: weekStart, initial: true) { _, value in prepareDates(endingAt: value) }
            .onChange(of: weeks, initial: true) { _, value in displayedWeeks = value }
        }
        .frame(height: Spacing.medium * 7 + Spacing.xxs * 6)
        .accessibilityRepresentation { Text(summary) }
    }

    private var summary: String {
        let visible = dates.suffix(displayedWeeks * 7).filter { $0.date <= now }
        let written = visible.count(where: { (days[$0.id]?.added ?? 0) > 0 })
        let sum = visible.reduce(0) { $0 + (days[$1.id]?.added ?? 0) }
        return "過去\(displayedWeeks)週で\(written)日執筆、合計\(sum.formatted())字"
    }

    @ViewBuilder private func cell(_ day: HeatmapDate, value: Int) -> some View {
        let date = day.date
        let opacity = value == 0 ? 0 : value < 500 ? 0.25 : value < 2000 ? 0.45 : value < 5000 ? 0.7 : 1
        let shape = RoundedRectangle(cornerRadius: Spacing.xxs)
            .fill(value == 0 ? FuminiwaColor.sunken.color : FuminiwaColor.accent.color.opacity(opacity))
            .frame(width: Spacing.medium, height: Spacing.medium)
            .opacity(date > now ? 0 : 1)
        #if os(macOS)
        shape.help("\(day.label) +\(value.formatted())字")
        #else
        shape.contentShape(Rectangle()).onTapGesture {
            if date <= now {
                selectedDay = day.id
            }
        }
        #endif
    }
}
