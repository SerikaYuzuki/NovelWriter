import NovelWritingProgress
import SwiftUI

struct WritingGoalSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var characters: String
    @State private var hasDeadline: Bool
    @State private var deadline: Date
    private let calendar: WritingCalendar
    private let onSave: (WritingGoal?) -> Void
    private let hasGoal: Bool
    init(goal: WritingGoal?, calendar: WritingCalendar, onSave: @escaping (WritingGoal?) -> Void) {
        self.calendar = calendar; self.onSave = onSave; hasGoal = goal != nil
        _characters = State(initialValue: goal.map { String($0.characters) } ?? "")
        _hasDeadline = State(initialValue: goal?.deadline != nil)
        _deadline = State(initialValue: goal?.deadline.flatMap { calendar.date($0) } ?? Date())
    }

    private var validGoal: WritingGoal? {
        guard let value = Int(characters.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return WritingGoal(characters: value, deadline: hasDeadline ? calendar.key(deadline) : nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("目標字数（正の整数）", text: $characters)
                #if os(iOS)
                    .keyboardType(.numberPad)
                #endif
                if validGoal == nil {
                    Text("目標字数を正の整数で入力してください。")
                        .font(.caption).foregroundStyle(FuminiwaColor.textSecondary.color)
                }
                Toggle("締切を設定", isOn: $hasDeadline)
                if hasDeadline {
                    DatePicker("締切", selection: $deadline, displayedComponents: .date)
                }
                if hasGoal {
                    Button("目標を削除", role: .destructive) { onSave(nil); dismiss() }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("執筆の目標")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let value = validGoal {
                            onSave(value); dismiss()
                        }
                    }.disabled(validGoal == nil)
                }
            }
            #if os(macOS)
            .frame(minWidth: 360, minHeight: 300)
            #endif
        }
        .environment(\.calendar, calendar.calendar)
        .environment(\.timeZone, calendar.calendar.timeZone)
        #if os(iOS)
            .presentationDetents([.medium, .large])
        #endif
    }
}
