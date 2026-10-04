import SwiftUI

public struct AssistantFeedbackDetail: View {
    public init(record: AssistantFeedback?) {
        self.record = record
    }

    let record: AssistantFeedback?
    public var body: some View {
        if let record {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(record.title).font(.title2.bold())
                    Text(record.createdAt.formatted(date: .complete, time: .standard))
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    AssistantMarkdownView(source: record.markdown)
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }.textSelection(.enabled)
                .navigationTitle(record.purpose.rawValue)
        } else {
            ContentUnavailableView("回答を選択してください", systemImage: "text.bubble",
                                   description: Text("左の一覧から、保存した感想・アドバイスを読めます。"))
        }
    }
}
