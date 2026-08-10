import SwiftUI

struct IOSLibraryView: View {
    @Bindable var store: IOSDocumentStore
    let openDocument: (IOSPrivateDocumentID) -> Void
    let makeNewDocument: () -> Void

    var body: some View {
        Group {
            if store.libraryItems.isEmpty {
                ContentUnavailableView {
                    Label("作品がありません", systemImage: "books.vertical")
                } description: {
                    Text("新しい作品を作るか、Files／iCloud Driveから取り込めます。")
                } actions: {
                    Button("新規作品") {
                        makeNewDocument()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Files／iCloud Driveから取り込む…") {
                        store.isImporterPresented = true
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                libraryList
            }
        }
        .navigationTitle("作品")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                IOSAppearanceMenu()
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("新規作品", systemImage: "doc.badge.plus") {
                        makeNewDocument()
                    }
                    Button("Files／iCloud Driveから取り込む…", systemImage: "folder.badge.plus") {
                        store.isImporterPresented = true
                    }
                } label: {
                    Label("作品を追加", systemImage: "plus")
                }
                .accessibilityIdentifier("ios.library.add")
            }
        }
        .onAppear {
            Task {
                await store.refreshLibrary()
            }
        }
    }

    private var libraryList: some View {
        List {
            Section {
                ForEach(store.libraryItems) { item in
                    Button {
                        open(item)
                    } label: {
                        IOSLibraryRow(
                            item: item,
                            isCurrent: item.id.packageName == store.documentURL.lastPathComponent
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("ios.library.work.\(item.id.packageName)")
                }
            } header: {
                Text("このデバイスの作品")
            } footer: {
                Text("ここには、ふみにわ内の作業コピーが表示されます。FilesやiCloud Driveの原本は変更しません。")
            }
        }
        .refreshable {
            await store.refreshLibrary()
        }
    }

    private func open(_ item: IOSDocumentLibraryItem) {
        switch item.availability {
        case .available:
            openDocument(item.id)
        case .unreadable:
            store.operationErrorMessage = item.errorMessage
                ?? "この作業コピーを読み込めませんでした。他の作品はそのまま利用できます。"
        }
    }
}

private struct IOSLibraryRow: View {
    let item: IOSDocumentLibraryItem
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: item.availability == .available ? "book.closed" : "exclamationmark.triangle")
                .foregroundStyle(item.availability == .available ? IOSPalette.accent : Color.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(displayTitle)
                        .foregroundStyle(.primary)
                    if isCurrent {
                        Text("選択中")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                if let modificationDate = item.modificationDate {
                    Text(modificationDate, format: .dateTime.year().month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            if item.availability == .available {
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(displayTitle)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(accessibilityHint)
    }

    private var displayTitle: String {
        item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "名称未設定の作品"
            : item.title
    }

    private var detailText: String {
        switch item.availability {
        case .available:
            "\(item.chapterCount)章・\(item.episodeCount)話・\(item.characterCount)字"
        case .unreadable:
            "この作業コピーは開けません"
        }
    }

    private var accessibilityHint: String {
        switch item.availability {
        case .available:
            "作品ホームを開きます。"
        case .unreadable:
            "問題の説明を表示します。"
        }
    }

    private var accessibilityValue: String {
        var values: [String] = []
        if isCurrent {
            values.append("選択中")
        }
        values.append(detailText)
        if let modificationDate = item.modificationDate {
            values.append(
                "更新日時、\(modificationDate.formatted(date: .long, time: .shortened))"
            )
        }
        return values.joined(separator: "、")
    }
}
