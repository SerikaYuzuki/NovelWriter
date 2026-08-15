import SwiftUI

/// 作品全体の同期競合をiOS UIへ渡すための表示専用モデル。
/// 同期Domainのrevision型からadapterで変換し、ViewからEditorを変更しない。
enum IOSWorkConflictField: String, CaseIterable, Hashable, Sendable, Identifiable {
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

struct IOSWorkConflictFieldSummary: Hashable, Sendable {
    let field: IOSWorkConflictField
    let detail: String
    let requiresChoice: Bool

    init(
        _ field: IOSWorkConflictField,
        detail: String,
        requiresChoice: Bool = false
    ) {
        self.field = field
        self.detail = detail
        self.requiresChoice = requiresChoice
    }
}

struct IOSWorkConflictDetailBlock: Hashable, Sendable, Identifiable {
    let id: String
    let title: String
    let content: String
}

struct IOSWorkConflictFieldDetail: Hashable, Sendable {
    let field: IOSWorkConflictField
    let blocks: [IOSWorkConflictDetailBlock]
}

struct IOSWorkConflictRevisionPresentation: Hashable, Sendable, Identifiable {
    let id: String
    let sourceDescription: String
    let savedDescription: String
    let changes: [IOSWorkConflictFieldSummary]
    let details: [IOSWorkConflictFieldDetail]

    init(
        id: String,
        sourceDescription: String,
        savedDescription: String,
        changes: [IOSWorkConflictFieldSummary],
        details: [IOSWorkConflictFieldDetail] = []
    ) {
        self.id = id
        self.sourceDescription = sourceDescription
        self.savedDescription = savedDescription
        self.changes = changes
        self.details = details
    }

    func summary(for field: IOSWorkConflictField) -> IOSWorkConflictFieldSummary? {
        changes.first { $0.field == field }
    }

    func detail(for field: IOSWorkConflictField) -> IOSWorkConflictFieldDetail? {
        details.first { $0.field == field }
    }

    func accessibilitySummary(fields: [IOSWorkConflictField]) -> String {
        fields.map { field in
            if let summary = summary(for: field) {
                return "\(field.title)、\(summary.detail)"
            }
            return "\(field.title)、変更なし"
        }
        .joined(separator: "、")
    }
}

struct IOSWorkConflictReviewPresentation: Hashable, Sendable {
    let workTitle: String
    let local: IOSWorkConflictRevisionPresentation
    let remote: IOSWorkConflictRevisionPresentation
    let proposed: IOSWorkConflictRevisionPresentation?
    let localPanelTitle: String
    let remotePanelTitle: String
    let proposedPanelTitle: String
    let localActionTitle: String
    let remoteActionTitle: String
    let proposedActionTitle: String
    let localActionHint: String
    let remoteActionHint: String
    let proposedActionHint: String

    init(
        workTitle: String,
        local: IOSWorkConflictRevisionPresentation,
        remote: IOSWorkConflictRevisionPresentation,
        proposed: IOSWorkConflictRevisionPresentation?,
        localPanelTitle: String = "このiPhone",
        remotePanelTitle: String = "iCloudの版",
        proposedPanelTitle: String = "確認用下書き",
        localActionTitle: String = "このiPhoneを採用",
        remoteActionTitle: String = "iCloudの版を採用",
        proposedActionTitle: String = "確認用下書きを採用",
        localActionHint: String = "このiPhoneの作品全体を新しい統合版にします",
        remoteActionHint: String = "iCloudの作品全体を新しい統合版にします",
        proposedActionHint: String = "自動統合できた項目を含む確認用下書きを新しい統合版にします"
    ) {
        self.workTitle = workTitle
        self.local = local
        self.remote = remote
        self.proposed = proposed
        self.localPanelTitle = localPanelTitle
        self.remotePanelTitle = remotePanelTitle
        self.proposedPanelTitle = proposedPanelTitle
        self.localActionTitle = localActionTitle
        self.remoteActionTitle = remoteActionTitle
        self.proposedActionTitle = proposedActionTitle
        self.localActionHint = localActionHint
        self.remoteActionHint = remoteActionHint
        self.proposedActionHint = proposedActionHint
    }

    var fields: [IOSWorkConflictField] {
        IOSWorkConflictField.allCases
    }

    var detailFields: [IOSWorkConflictField] {
        fields.filter { field in
            local.detail(for: field) != nil
                || remote.detail(for: field) != nil
                || proposed?.detail(for: field) != nil
        }
    }

    var comparisonAccessibilityHint: String {
        let titles = [localPanelTitle, remotePanelTitle]
            + (proposed == nil ? [] : [proposedPanelTitle])
        return "横に動かすと、\(titles.joined(separator: "、"))の順に比較できます"
    }
}

enum IOSWorkConflictReviewChoice: Hashable, Sendable {
    case keepLocal
    case keepRemote
    case useProposed
}

enum IOSWorkConflictReviewMode: Hashable, Sendable {
    case cloudConflict
    case localRecovery
}

/// 狭いiPhoneでも横スクロールで3版を比較できる、dismiss可能な確認sheet content。
struct IOSWorkConflictResolutionView: View {
    let presentation: IOSWorkConflictReviewPresentation
    let isApplying: Bool
    var mode: IOSWorkConflictReviewMode = .cloudConflict
    let choose: (IOSWorkConflictReviewChoice) -> Void
    let reviewLater: () -> Void

    @State private var detailedField: IOSWorkConflictField?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    intro
                    comparison
                    actions
                }
                .padding(16)
            }
            .navigationTitle("変更の確認")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("あとで") { reviewLater() }
                        .accessibilityHint(reviewLaterHint)
                        .accessibilityIdentifier("ios.workConflict.reviewLater")
                }
            }
        }
        .accessibilityIdentifier("ios.workConflict.review")
        .sheet(item: $detailedField) { field in
            IOSWorkConflictFieldDetailView(
                presentation: presentation,
                field: field,
                dismiss: { detailedField = nil }
            )
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(introTitle, systemImage: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.orange)
            Text(introMessage)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(reviewRetentionMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var displayWorkTitle: String {
        presentation.workTitle.isEmpty ? "名称未設定の作品" : presentation.workTitle
    }

    private var introTitle: String {
        mode == .localRecovery ? "端末内の保存版を確認してください" : "変更の確認が必要です"
    }

    private var reviewLaterHint: String {
        mode == .localRecovery
            ? "版を選ばずに閉じます。編集を再開するには保存版の選択が必要です"
            : "版を選ばずに閉じます。端末内の編集は続けられます"
    }

    private var reviewRetentionMessage: String {
        mode == .localRecovery
            ? "選ぶまではすべての版を保持し、作品の編集を止めます。"
            : "閉じても編集は続けられます。選ぶまでは両方の版を保持します。"
    }

    private var introMessage: String {
        switch mode {
        case .cloudConflict:
            "「\(displayWorkTitle)」は、このiPhoneとiCloudの両方で変更されています。横に動かして内容を比べられます。"
        case .localRecovery:
            "「\(displayWorkTitle)」には保存途中の版が複数残っています。横に動かして、続きを書く版を選んでください。"
        }
    }

    private var comparison: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 12) {
                revisionPanel(
                    title: presentation.localPanelTitle,
                    systemImage: "iphone",
                    revision: presentation.local
                )
                revisionPanel(
                    title: presentation.remotePanelTitle,
                    systemImage: "icloud",
                    revision: presentation.remote
                )
                proposedPanel
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .accessibilityHint(presentation.comparisonAccessibilityHint)
    }

    private func revisionPanel(
        title: String,
        systemImage: String,
        revision: IOSWorkConflictRevisionPresentation
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
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(presentation.fields) { field in
                    fieldRow(field, in: revision)
                }
            }
        }
        .padding(12)
        .frame(width: 280, alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(revisionAccessibilityLabel(title: title, revision: revision))
    }

    private func revisionAccessibilityLabel(
        title: String,
        revision: IOSWorkConflictRevisionPresentation
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
        } else if mode == .cloudConflict {
            VStack(alignment: .leading, spacing: 8) {
                Label("確認用下書き", systemImage: "doc.badge.gearshape")
                    .font(.headline)
                ContentUnavailableView(
                    "自動統合できませんでした",
                    systemImage: "arrow.triangle.branch",
                    description: Text("このiPhoneかiCloudの版を選べます。選ぶまでは両方の版を保持します。")
                )
                .frame(maxWidth: .infinity, minHeight: 320)
            }
            .padding(12)
            .frame(width: 280, alignment: .topLeading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator) }
            .accessibilityIdentifier("ios.workConflict.noProposedDraft")
        }
    }

    private func fieldRow(
        _ field: IOSWorkConflictField,
        in revision: IOSWorkConflictRevisionPresentation
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

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !presentation.detailFields.isEmpty {
                Menu("項目の全文を比較") {
                    ForEach(presentation.detailFields) { field in
                        Button(field.title) { detailedField = field }
                    }
                }
                .accessibilityLabel("項目の全文を比較")
                .accessibilityHint("採用する前に、各保存版の全文を項目ごとに比べます")
                .accessibilityIdentifier("ios.workConflict.openFullComparison")
            }
            Button(presentation.localActionTitle) {
                choose(.keepLocal)
            }
            .buttonStyle(.bordered)
            .accessibilityHint(presentation.localActionHint)
            .accessibilityIdentifier("ios.workConflict.keepLocal")
            Button(presentation.remoteActionTitle) {
                choose(.keepRemote)
            }
            .buttonStyle(.bordered)
            .accessibilityHint(presentation.remoteActionHint)
            .accessibilityIdentifier("ios.workConflict.keepRemote")
            if presentation.proposed != nil {
                Button(presentation.proposedActionTitle) {
                    choose(.useProposed)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint(presentation.proposedActionHint)
                .accessibilityIdentifier("ios.workConflict.useProposed")
            }
            if isApplying {
                ProgressView("作品を統合しています")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(isApplying)
    }
}

private struct IOSWorkConflictFieldDetailView: View {
    let presentation: IOSWorkConflictReviewPresentation
    let field: IOSWorkConflictField
    let dismiss: () -> Void

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 12) {
                        detailPanel(
                            title: presentation.localPanelTitle,
                            revision: presentation.local,
                            height: proxy.size.height - 32
                        )
                        detailPanel(
                            title: presentation.remotePanelTitle,
                            revision: presentation.remote,
                            height: proxy.size.height - 32
                        )
                        if let proposed = presentation.proposed {
                            detailPanel(
                                title: presentation.proposedPanelTitle,
                                revision: proposed,
                                height: proxy.size.height - 32
                            )
                        }
                    }
                    .padding(16)
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
            }
            .navigationTitle("\(field.title)の全文比較")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる", action: dismiss)
                }
            }
        }
        .accessibilityIdentifier("ios.workConflict.fullComparison")
    }

    private func detailPanel(
        title: String,
        revision: IOSWorkConflictRevisionPresentation,
        height: CGFloat
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
        .frame(width: 300, height: max(320, height), alignment: .topLeading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title)、\(field.title)の全文")
    }
}
