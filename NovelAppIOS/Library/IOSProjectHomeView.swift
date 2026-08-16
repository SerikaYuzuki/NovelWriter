import NovelCore
import SwiftUI

struct IOSProjectHomeView: View {
    let store: IOSDocumentStore
    let openWriting: () -> Void
    let openProjectInfo: () -> Void
    let openPlot: () -> Void
    let openCharacters: () -> Void
    let openWorldbuilding: () -> Void
    let openReferences: () -> Void
    let openSettings: () -> Void
    @Environment(\.iosNoteSyncConflictPresented) private var isNoteSyncConflictPresented
    @State private var isSnapshotPresented = false

    var body: some View {
        List {
            headerSection
            cloudSection
            workSection
            appSection
            exportSection
        }
        .navigationTitle(displayTitle)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                IOSSnapshotToolbarButton(
                    accessibilityIdentifier: "ios.project.snapshot",
                    isPresented: $isSnapshotPresented
                )
            }
        }
        .iosSnapshotSheet(store: store, isPresented: $isSnapshotPresented)
    }

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(displayTitle)
                    .font(.title2.weight(.semibold))
                synopsisText
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(displayTitle)
            .accessibilityValue(projectAccessibilityValue)
        }
    }

    @ViewBuilder
    private var synopsisText: some View {
        if store.document.synopsis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("作品情報から、あらすじを追加できます。")
                .foregroundStyle(.secondary)
        } else {
            Text(store.document.synopsis)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
    }

    @ViewBuilder
    private var cloudSection: some View {
        if store.usesSnapshotSyncRuntime {
            snapshotSyncSection
        } else if store.canPublishCurrentWorkToCloud {
            Section {
                Button {
                    Task {
                        guard let workID = store.activeCloudWorkID else { return }
                        _ = await store.publishCloudLibraryWork(workID)
                    }
                } label: {
                    Label("サーバーに保存", systemImage: "arrow.up.circle")
                }
                .disabled(
                    !store.permitsCloudLibraryMutation || store.cloudLibraryOperationInProgress
                )
                .accessibilityIdentifier("ios.project.publish")
            } footer: {
                Text("この端末だけの作品です。サーバーへ送るまで、ほかの端末には出ません。")
            }
        } else if store.noteSyncConflict != nil {
            Section {
                Button {
                    isNoteSyncConflictPresented.wrappedValue = true
                } label: {
                    Label("変更の確認が必要です", systemImage: "exclamationmark.triangle")
                }
                .tint(.orange)
                .accessibilityIdentifier("ios.project.noteSync.review")
            } footer: {
                Text("この端末とサーバーの両方で内容が変わっています。残す側を選べます。")
            }
        } else if store.canExplicitlySyncCurrentWork {
            Section {
                Button {
                    Task {
                        if store.usesSnapshotSyncRuntime {
                            _ = await store.saveAndSyncSnapshotNow()
                        } else {
                            _ = await store.saveAndSyncNow()
                        }
                    }
                } label: {
                    Label("サーバーと同期", systemImage: "arrow.clockwise")
                }
                .disabled(store.isExplicitNoteSyncInFlight)
                .keyboardShortcut("s", modifiers: .command)
                .accessibilityIdentifier("ios.project.sync")
            } footer: {
                Text("この端末への保存は自動です。サーバーへ送るときだけ、この操作またはCommand-Sを使います。")
            }
        }
    }

    private var snapshotSyncSection: some View {
        Section {
            switch store.authUIState {
            case .signedOut, .failed:
                Label(
                    "この端末への保存は自動です。サーバーへ送るにはAppleでサインインしてください。",
                    systemImage: "person.crop.circle.badge.plus"
                )
                .foregroundStyle(.secondary)

                Button("Appleでサインイン") {
                    Task { await store.signInWithApple() }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("ios.project.snapshot.signInWithApple")
            case .signingIn:
                Label("Appleでサインインしています…", systemImage: "person.crop.circle")
                ProgressView()
            case .signedIn:
                Label(snapshotSyncTitle, systemImage: snapshotSyncIcon)
                    .foregroundStyle(snapshotSyncIsWarning ? .orange : .secondary)

                if snapshotSyncIsWarning {
                    Text(snapshotSyncDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    if case .offline = store.snapshotSyncOutcome {
                        Button {
                            Task { _ = await store.saveAndSyncSnapshotNow() }
                        } label: {
                            Label("接続を確認して再試行", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!store.canExplicitlySyncCurrentWork)
                        .accessibilityIdentifier("ios.project.snapshot.retry")
                    }

                    if let conflict = store.snapshotSyncConflict {
                        Text("競合ID: \(conflict.conflictID.uuidString.prefix(8))")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } else {
                    Button {
                        Task { _ = await store.saveAndSyncSnapshotNow() }
                    } label: {
                        Label("今すぐサーバーへ送る", systemImage: "arrow.up.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.canExplicitlySyncCurrentWork)
                    .accessibilityIdentifier("ios.project.snapshot.syncNow")
                }
            case .unavailable:
                Label("サーバー同期を利用できません。", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("サーバー同期")
        } footer: {
            Text("原稿は先にこの端末へ保存されます。通信できないときも編集を続けられ、接続が戻ると送信を再開します。")
        }
    }

    private var snapshotSyncTitle: String {
        switch store.snapshotSyncOutcome {
        case .notStarted:
            "サーバー同期の準備ができています"
        case .uploaded:
            "この端末とサーバーに保存済み"
        case .idle:
            "変更はありません。同期済みです"
        case .offline:
            "この端末に保存済み。通信待ちです"
        case .needsChoice:
            "競合の確認が必要です"
        }
    }

    private var snapshotSyncDescription: String {
        switch store.snapshotSyncOutcome {
        case .notStarted:
            "「今すぐサーバーへ送る」を押すと、この作品を初めてサーバーへ保存します。"
        case .uploaded, .idle:
            "編集内容はこの端末とサーバーの両方に保存されています。"
        case .offline:
            "編集内容はこの端末に保存されています。接続が戻ると自動で送信します。"
        case .needsChoice:
            "端末の版とサーバーの版を両方保持しています。勝手に上書きせず、選択が必要です。"
        }
    }

    private var snapshotSyncIcon: String {
        switch store.snapshotSyncOutcome {
        case .notStarted: "arrow.up.circle"
        case .uploaded, .idle: "checkmark.circle"
        case .offline: "wifi.slash"
        case .needsChoice: "exclamationmark.triangle"
        }
    }

    private var snapshotSyncIsWarning: Bool {
        switch store.snapshotSyncOutcome {
        case .offline, .needsChoice:
            true
        case .notStarted, .uploaded, .idle:
            false
        }
    }

    private var workSection: some View {
        Section("この作品") {
            IOSProjectActionRow(
                title: "作品情報",
                description: "作品タイトルとあらすじを編集します。",
                systemImage: "doc.text.magnifyingglass",
                action: openProjectInfo
            )
            .accessibilityIdentifier("ios.project.info")

            IOSProjectActionRow(
                title: "執筆",
                description: "章と話を選んで本文を編集します。",
                systemImage: "square.and.pencil",
                action: openWriting
            )
            .accessibilityIdentifier("ios.project.writing")

            IOSProjectActionRow(
                title: "プロット",
                description: "構成カードと伏線を整理します。",
                systemImage: "rectangle.stack",
                action: openPlot
            )
            .accessibilityIdentifier("ios.project.plot")

            IOSProjectActionRow(
                title: "登場人物",
                description: "人物の名前や設定を編集します。",
                systemImage: "person.2",
                action: openCharacters
            )
            .accessibilityIdentifier("ios.project.characters")

            IOSProjectActionRow(
                title: "世界観",
                description: "舞台や用語のノートを編集します。",
                systemImage: "globe.asia.australia",
                action: openWorldbuilding
            )
            .accessibilityIdentifier("ios.project.worldbuilding")

            IOSProjectActionRow(
                title: "資料",
                description: "作品に取り込んだ資料を管理します。",
                systemImage: "paperclip",
                action: openReferences
            )
            .accessibilityIdentifier("ios.project.references")
        }
    }

    private var appSection: some View {
        Section("アプリ") {
            IOSProjectActionRow(
                title: "設定",
                description: "アプリの外観を選びます。",
                systemImage: "gearshape",
                action: openSettings
            )
            .accessibilityIdentifier("ios.project.settings")
        }
    }

    private var exportSection: some View {
        Section {
            Button {
                Task {
                    await store.requestExport()
                }
            } label: {
                Label("作品を書き出す…", systemImage: "square.and.arrow.up")
            }
            .accessibilityHint("現在の作業コピーから、共有用のnovelpkgファイルを作ります。")
        } header: {
            Text("共有")
        } footer: {
            Text("編集しているのは、ふみにわ内の作業コピーです。書き出しても編集先は変わりません。")
        }
    }

    private var displayTitle: String {
        store.document.title.isEmpty ? "名称未設定の作品" : store.document.title
    }

    private var summaryText: String {
        let chapterCount = store.document.chapters.count
        let episodeCount = store.document.chapters.reduce(0) { $0 + $1.episodes.count }
        let characterCount = store.document.chapters.reduce(0) { chapterTotal, chapter in
            chapterTotal + chapter.episodes.reduce(0) { episodeTotal, episode in
                episodeTotal + ManuscriptMetrics.countCharacters(in: episode.content)
            }
        }
        return "\(chapterCount)章・\(episodeCount)話・\(characterCount)字"
    }

    private var projectAccessibilityValue: String {
        let synopsis = store.document.synopsis.trimmingCharacters(in: .whitespacesAndNewlines)
        let synopsisDescription = synopsis.isEmpty
            ? "あらすじ未設定"
            : "あらすじ、\(synopsis)"
        return "\(synopsisDescription)、\(summaryText)"
    }
}

struct IOSProjectInfoView: View {
    let store: IOSDocumentStore

    var body: some View {
        Form {
            Section("基本情報") {
                TextField("作品タイトル", text: documentTitle)
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("ios.project.title")

                VStack(alignment: .leading, spacing: 8) {
                    Text("あらすじ")
                        .font(.headline)
                    TextEditor(text: documentSynopsis)
                        .frame(minHeight: 160)
                        .accessibilityLabel("あらすじ")
                        .accessibilityIdentifier("ios.project.synopsis")
                }
                .padding(.vertical, 8)
            }

            Section("原稿") {
                LabeledContent("章", value: "\(store.document.chapters.count)")
                LabeledContent("話", value: "\(episodeCount)")
                LabeledContent("文字数", value: "\(characterCount)字")
            }
            .monospacedDigit()
        }
        .navigationTitle("作品情報")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var documentTitle: Binding<String> {
        Binding(
            get: { store.document.title },
            set: { store.updateDocumentTitle($0) }
        )
    }

    private var documentSynopsis: Binding<String> {
        Binding(
            get: { store.document.synopsis },
            set: { store.updateDocumentSynopsis($0) }
        )
    }

    private var episodeCount: Int {
        store.document.chapters.reduce(0) { $0 + $1.episodes.count }
    }

    private var characterCount: Int {
        store.document.chapters.reduce(0) { chapterTotal, chapter in
            chapterTotal + chapter.episodes.reduce(0) { episodeTotal, episode in
                episodeTotal + ManuscriptMetrics.countCharacters(in: episode.content)
            }
        }
    }
}

private struct IOSProjectActionRow: View {
    let title: String
    let description: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .frame(width: 24)
                    .foregroundStyle(IOSPalette.accent)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(description)
    }
}
