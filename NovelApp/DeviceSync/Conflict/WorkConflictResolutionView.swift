import SwiftUI

/// 作品全体の同期競合をUIへ渡すための表示専用モデル。
///
/// 同期Domainのrevision型とは分離しておき、Domain側で競合が確定したあとに
/// adapterでこの型へ変換する。ViewからEditorやpackageを直接変更しない。
enum WorkConflictField: String, CaseIterable, Hashable, Sendable, Identifiable {
    case title
    case synopsis
    case chapters
    case episodes
    case episodeBodies
    case episodeMemos
    case characters
    case plotCards
    case flags
    case worldNotes

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .title: "作品タイトル"
        case .synopsis: "あらすじ"
        case .chapters: "章構成"
        case .episodes: "話構成"
        case .episodeBodies: "本文"
        case .episodeMemos: "話メモ"
        case .characters: "登場人物"
        case .plotCards: "プロット"
        case .flags: "伏線"
        case .worldNotes: "世界観"
        }
    }

    var systemImage: String {
        switch self {
        case .title: "textformat"
        case .synopsis: "text.alignleft"
        case .chapters: "list.bullet.indent"
        case .episodes: "doc.text"
        case .episodeBodies: "pencil.line"
        case .episodeMemos: "note.text"
        case .characters: "person.2"
        case .plotCards: "rectangle.3.group"
        case .flags: "flag"
        case .worldNotes: "globe.asia.australia"
        }
    }
}

struct WorkConflictFieldSummary: Hashable, Sendable {
    let field: WorkConflictField
    let detail: String
    let requiresChoice: Bool

    init(
        _ field: WorkConflictField,
        detail: String,
        requiresChoice: Bool = false
    ) {
        self.field = field
        self.detail = detail
        self.requiresChoice = requiresChoice
    }
}

struct WorkConflictDetailBlock: Hashable, Sendable, Identifiable {
    let id: String
    let title: String
    let content: String
}

struct WorkConflictFieldDetail: Hashable, Sendable {
    let field: WorkConflictField
    let blocks: [WorkConflictDetailBlock]
}

struct WorkConflictRevisionPresentation: Hashable, Sendable, Identifiable {
    let id: String
    let sourceDescription: String
    let savedDescription: String
    let changes: [WorkConflictFieldSummary]
    let details: [WorkConflictFieldDetail]

    init(
        id: String,
        sourceDescription: String,
        savedDescription: String,
        changes: [WorkConflictFieldSummary],
        details: [WorkConflictFieldDetail] = []
    ) {
        self.id = id
        self.sourceDescription = sourceDescription
        self.savedDescription = savedDescription
        self.changes = changes
        self.details = details
    }

    func summary(for field: WorkConflictField) -> WorkConflictFieldSummary? {
        changes.first { $0.field == field }
    }

    func detail(for field: WorkConflictField) -> WorkConflictFieldDetail? {
        details.first { $0.field == field }
    }

    func accessibilitySummary(fields: [WorkConflictField]) -> String {
        fields.map { field in
            if let summary = summary(for: field) {
                return "\(field.title)、\(summary.detail)"
            }
            return "\(field.title)、変更なし"
        }
        .joined(separator: "、")
    }
}

struct WorkConflictReviewPresentation: Hashable, Sendable {
    let workTitle: String
    let local: WorkConflictRevisionPresentation
    let remote: WorkConflictRevisionPresentation
    let proposed: WorkConflictRevisionPresentation?
    let heading: String
    let message: String?
    let footnote: String
    let localPanelTitle: String
    let remotePanelTitle: String
    let proposedPanelTitle: String
    let localActionTitle: String
    let remoteActionTitle: String
    let proposedActionTitle: String
    let localActionHint: String
    let remoteActionHint: String
    let proposedActionHint: String
    let canChooseRemote: Bool
    let canChooseProposed: Bool

    init(
        workTitle: String,
        local: WorkConflictRevisionPresentation,
        remote: WorkConflictRevisionPresentation,
        proposed: WorkConflictRevisionPresentation?,
        heading: String = "変更の確認が必要です",
        message: String? = nil,
        footnote: String = "閉じても編集は続けられます。選ぶまでは両方の版を保持します。",
        localPanelTitle: String = "この端末",
        remotePanelTitle: String = "iCloudの版",
        proposedPanelTitle: String = "確認用下書き",
        localActionTitle: String = "この端末を採用",
        remoteActionTitle: String = "iCloudの版を採用",
        proposedActionTitle: String = "確認用下書きを採用",
        localActionHint: String = "この端末の作品全体を新しい統合版にします",
        remoteActionHint: String = "iCloudの作品全体を新しい統合版にします",
        proposedActionHint: String = "自動統合できた項目を含む確認用下書きを新しい統合版にします",
        canChooseRemote: Bool = true,
        canChooseProposed: Bool = true
    ) {
        self.workTitle = workTitle
        self.local = local
        self.remote = remote
        self.proposed = proposed
        self.heading = heading
        self.message = message
        self.footnote = footnote
        self.localPanelTitle = localPanelTitle
        self.remotePanelTitle = remotePanelTitle
        self.proposedPanelTitle = proposedPanelTitle
        self.localActionTitle = localActionTitle
        self.remoteActionTitle = remoteActionTitle
        self.proposedActionTitle = proposedActionTitle
        self.localActionHint = localActionHint
        self.remoteActionHint = remoteActionHint
        self.proposedActionHint = proposedActionHint
        self.canChooseRemote = canChooseRemote
        self.canChooseProposed = canChooseProposed
    }

    var fields: [WorkConflictField] {
        WorkConflictField.allCases
    }

    var detailFields: [WorkConflictField] {
        fields.filter { field in
            local.detail(for: field) != nil
                || remote.detail(for: field) != nil
                || proposed?.detail(for: field) != nil
        }
    }
}

enum WorkConflictReviewChoice: Hashable, Sendable {
    case keepLocal
    case keepRemote
    case useProposed
}

/// 作品全体の2版と確認用下書きを比較するmacOS用sheet content。
///
/// `choose`は利用者の明示操作だけを通知する。表示中・dismiss時にEditor本文へ
/// revisionを注入しないため、利用者は「あとで」で閉じてlocal編集を続けられる。
struct WorkConflictResolutionView: View {
    let presentation: WorkConflictReviewPresentation
    let isApplying: Bool
    let choose: (WorkConflictReviewChoice) -> Void
    let reviewLater: () -> Void

    @State private var detailedField: WorkConflictField?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            HStack(alignment: .top, spacing: 12) {
                revisionPanel(
                    title: presentation.localPanelTitle,
                    systemImage: "macbook",
                    revision: presentation.local
                )
                revisionPanel(
                    title: presentation.remotePanelTitle,
                    systemImage: "icloud",
                    revision: presentation.remote
                )
                proposedPanel
            }

            Divider()

            actionBar
        }
        .padding(20)
        .frame(minWidth: 960, minHeight: 640)
        .accessibilityIdentifier("workConflict.review")
        .sheet(item: $detailedField) { field in
            WorkConflictFieldDetailView(
                presentation: presentation,
                field: field,
                dismiss: { detailedField = nil }
            )
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Label(presentation.heading, systemImage: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text(presentation.message
                    ?? "「\(displayWorkTitle)」は、この端末とiCloudの両方で変更されています。内容を比べて、残す版を選べます。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(presentation.footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("あとで") { reviewLater() }
                .buttonStyle(.bordered)
                .accessibilityHint("版を選ばずに比較画面を閉じます")
                .accessibilityIdentifier("workConflict.reviewLater")
        }
    }

    private var displayWorkTitle: String {
        presentation.workTitle.isEmpty ? "名称未設定の作品" : presentation.workTitle
    }

    private func revisionPanel(
        title: String,
        systemImage: String,
        revision: WorkConflictRevisionPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Text(revision.sourceDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(revision.savedDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(presentation.fields) { field in
                        fieldRow(field, in: revision)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 440, maxHeight: 440, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(revisionAccessibilityLabel(title: title, revision: revision))
    }

    private func revisionAccessibilityLabel(
        title: String,
        revision: WorkConflictRevisionPresentation
    ) -> String {
        [title, revision.sourceDescription, revision.accessibilitySummary(fields: presentation.fields)]
            .joined(separator: "。")
    }

    @ViewBuilder
    private var proposedPanel: some View {
        if let proposed = presentation.proposed {
            revisionPanel(
                title: presentation.proposedPanelTitle,
                systemImage: "doc.badge.gearshape",
                revision: proposed
            )
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label(presentation.proposedPanelTitle, systemImage: "doc.badge.gearshape")
                    .font(.headline)
                ContentUnavailableView(
                    "自動統合できませんでした",
                    systemImage: "arrow.triangle.branch",
                    description: Text("この端末かiCloudの、どちらかの版を選べます。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 440, maxHeight: 440, alignment: .topLeading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator) }
            .accessibilityIdentifier("workConflict.noProposedDraft")
        }
    }

    private func fieldRow(
        _ field: WorkConflictField,
        in revision: WorkConflictRevisionPresentation
    ) -> some View {
        let summary = revision.summary(for: field)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: summary?.requiresChoice == true ? "exclamationmark.circle" : field.systemImage)
                .foregroundStyle(summary?.requiresChoice == true ? .orange : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 4) {
                Text(field.title)
                    .font(.body)
                Text(summary?.detail ?? "変更なし")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(field.title)、\(summary?.detail ?? "変更なし")")
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            if !presentation.detailFields.isEmpty {
                Menu("項目の全文を比較") {
                    ForEach(presentation.detailFields) { field in
                        Button(field.title) { detailedField = field }
                    }
                }
                .accessibilityLabel("項目の全文を比較")
                .accessibilityHint("採用する前に、この端末、iCloud、確認用下書きの全文を項目ごとに比べます")
                .accessibilityIdentifier("workConflict.openFullComparison")
            }
            Button(presentation.localActionTitle) { choose(.keepLocal) }
                .buttonStyle(.bordered)
                .accessibilityHint(presentation.localActionHint)
                .accessibilityIdentifier("workConflict.keepLocal")
            if presentation.canChooseRemote {
                Button(presentation.remoteActionTitle) { choose(.keepRemote) }
                    .buttonStyle(.bordered)
                    .accessibilityHint(presentation.remoteActionHint)
                    .accessibilityIdentifier("workConflict.keepRemote")
            }
            Spacer()
            if presentation.proposed != nil, presentation.canChooseProposed {
                Button(presentation.proposedActionTitle) { choose(.useProposed) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint(presentation.proposedActionHint)
                    .accessibilityIdentifier("workConflict.useProposed")
            }
            if isApplying {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("作品を統合しています")
            }
        }
        .disabled(isApplying)
    }
}

private struct WorkConflictFieldDetailView: View {
    let presentation: WorkConflictReviewPresentation
    let field: WorkConflictField
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(field.title)の全文比較")
                        .font(.title2)
                    Text("採用する版を決める前に、各版の内容を最後まで確認できます。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("閉じる", action: dismiss)
                    .keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .top, spacing: 12) {
                detailPanel(
                    title: presentation.localPanelTitle,
                    revision: presentation.local
                )
                detailPanel(
                    title: presentation.remotePanelTitle,
                    revision: presentation.remote
                )
                if let proposed = presentation.proposed {
                    detailPanel(
                        title: presentation.proposedPanelTitle,
                        revision: proposed
                    )
                }
            }
        }
        .padding(20)
        .frame(minWidth: 960, minHeight: 640)
        .accessibilityIdentifier("workConflict.fullComparison")
    }

    private func detailPanel(
        title: String,
        revision: WorkConflictRevisionPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(revision.sourceDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let detail = revision.detail(for: field), !detail.blocks.isEmpty {
                        ForEach(detail.blocks) { block in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(block.title)
                                    .font(.subheadline.weight(.semibold))
                                if block.content.isEmpty {
                                    Text("（空欄）")
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text(block.content)
                                        .textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .combine)
                        }
                    } else {
                        Text("この項目はありません")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title)、\(field.title)の全文")
    }
}
