import NovelCore
import NovelUI
import NovelWorkspace
import SwiftUI

enum IOSPlotSelection: Hashable {
    case card(PlotCardID)
    case flag(FlagID)
}

@MainActor
struct IOSPlotFeatureView: View {
    let store: IOSDocumentStore
    let expectedSession: WorkspaceSessionToken?
    @State private var selection: IOSPlotSelection?

    init(store: IOSDocumentStore) {
        self.store = store
        expectedSession = store.currentDocumentSessionToken
    }

    var body: some View {
        IOSPlotOutlineView(
            store: store,
            selection: $selection,
            expectedSession: expectedSession,
            usesNavigationLinks: true
        )
    }
}

struct IOSPlotOutlineView: View {
    let store: IOSDocumentStore
    @Binding var selection: IOSPlotSelection?
    let expectedSession: WorkspaceSessionToken?
    let usesNavigationLinks: Bool

    @State private var editMode: EditMode = .inactive
    private var usesGrid: Bool {
        sizeClass == .regular && !dynamicTypeSize.isAccessibilitySize && !editMode.isEditing
    }

    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var deletionRequest: IOSPlotDeletionRequest?

    var body: some View {
        List {
            Section("プロットカード") {
                if usesGrid {
                    cardGrid
                } else {
                    ForEach(store.document.plotCards) { card in
                        plotCardRow(card)
                    }
                    .onDelete(perform: requestPlotCardDeletion)
                    .onMove { offsets, destination in
                        guard let expectedSession else { return }
                        _ = store.movePlotCards(
                            fromOffsets: offsets,
                            toOffset: destination,
                            expectedSession: expectedSession
                        )
                    }
                }
            }

            Section("伏線") {
                if usesGrid {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .top)], spacing: Spacing.medium) {
                        ForEach(store.document.flags) { flag in
                            flagRow(flag).surfaceCard(selected: selection == .flag(flag.id))
                                .contextMenu {
                                    Button("削除…", role: .destructive) { requestDeletion(flag) }
                                }
                        }
                    }
                } else {
                    ForEach(store.document.flags) { flag in
                        flagRow(flag)
                    }
                    .onDelete(perform: requestFlagDeletion)
                    .onMove { offsets, destination in
                        guard let expectedSession else { return }
                        _ = store.moveFlags(
                            fromOffsets: offsets,
                            toOffset: destination,
                            expectedSession: expectedSession
                        )
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(FuminiwaColor.paper.color)
        .overlay {
            if store.document.plotCards.isEmpty, store.document.flags.isEmpty {
                ContentUnavailableView {
                    Label("プロットがありません", systemImage: "rectangle.stack")
                } actions: {
                    Button("プロットカードを追加") {
                        guard let expectedSession else { return }
                        if let id = store.addPlotCard(expectedSession: expectedSession) {
                            selection = .card(id)
                        }
                    }
                    .disabled(expectedSession == nil)
                    Button("伏線を追加") {
                        guard let expectedSession else { return }
                        if let id = store.addFlag(expectedSession: expectedSession) {
                            selection = .flag(id)
                        }
                    }
                    .disabled(expectedSession == nil)
                }
                .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(FuminiwaColor.separator.color, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                .padding(Spacing.outer)
            }
        }
        .navigationTitle("プロット")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        guard let expectedSession else { return }
                        if let id = store.addPlotCard(expectedSession: expectedSession) {
                            selection = .card(id)
                        }
                    } label: {
                        Label("プロットカードを追加", systemImage: "rectangle.stack.badge.plus")
                    }

                    Button {
                        guard let expectedSession else { return }
                        if let id = store.addFlag(expectedSession: expectedSession) {
                            selection = .flag(id)
                        }
                    } label: {
                        Label("伏線を追加", systemImage: "flag.badge.plus")
                    }
                } label: {
                    Label("追加", systemImage: "plus")
                }
                .disabled(expectedSession == nil)
                .accessibilityIdentifier("ios.plot.add")
            }

            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }

        .confirmationDialog(
            deletionRequest?.title ?? "削除しますか？",
            isPresented: deletionRequestIsPresented,
            presenting: deletionRequest
        ) { request in
            Button("削除", role: .destructive) {
                performDeletion(request)
            }
            Button("キャンセル", role: .cancel) {}
        } message: { request in
            Text(request.message)
        }
        .environment(\.editMode, $editMode)
    }

    private func requestDeletion(_ flag: Flag) {
        guard let index = store.document.flags.firstIndex(where: { $0.id == flag.id }) else { return }
        requestFlagDeletion(at: IndexSet(integer: index))
    }

    private func requestDeletion(_ card: PlotCard) {
        guard let index = store.document.plotCards.firstIndex(where: { $0.id == card.id }) else { return }
        requestPlotCardDeletion(at: IndexSet(integer: index))
    }

    private var cardGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .top)], spacing: Spacing.medium) {
            ForEach(store.document.plotCards) { card in
                plotCardRow(card)
                    .surfaceCard(selected: selection == .card(card.id))
                    .contextMenu {
                        Button("削除…", role: .destructive) {
                            requestDeletion(card)
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private func plotCardRow(_ card: PlotCard) -> some View {
        if usesNavigationLinks {
            NavigationLink {
                IOSPlotDetailView(
                    store: store,
                    selection: .card(card.id),
                    expectedSession: expectedSession,
                    dismissAfterDeletion: true
                )
            } label: {
                IOSPlotCardRow(card: card, chapterTitle: chapterTitle(for: card.chapterID))
            }
        } else {
            Button {
                selection = .card(card.id)
            } label: {
                IOSPlotCardRow(card: card, chapterTitle: chapterTitle(for: card.chapterID))
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selection == .card(card.id) ? .isSelected : [])
        }
    }

    @ViewBuilder
    private func flagRow(_ flag: Flag) -> some View {
        if usesNavigationLinks {
            NavigationLink {
                IOSPlotDetailView(
                    store: store,
                    selection: .flag(flag.id),
                    expectedSession: expectedSession,
                    dismissAfterDeletion: true
                )
            } label: {
                IOSFlagRow(flag: flag, chapterTitle: chapterTitle(for: flag.plantedChapterID))
            }
        } else {
            Button {
                selection = .flag(flag.id)
            } label: {
                IOSFlagRow(flag: flag, chapterTitle: chapterTitle(for: flag.plantedChapterID))
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selection == .flag(flag.id) ? .isSelected : [])
        }
    }

    private func requestPlotCardDeletion(at offsets: IndexSet) {
        let ids = offsets.compactMap { index in
            store.document.plotCards.indices.contains(index) ? store.document.plotCards[index].id : nil
        }
        guard !ids.isEmpty, let expectedSession else { return }
        deletionRequest = IOSPlotDeletionRequest(
            expectedSession: expectedSession,
            target: .cards(ids)
        )
    }

    private func requestFlagDeletion(at offsets: IndexSet) {
        let ids = offsets.compactMap { index in
            store.document.flags.indices.contains(index) ? store.document.flags[index].id : nil
        }
        guard !ids.isEmpty, let expectedSession else { return }
        deletionRequest = IOSPlotDeletionRequest(
            expectedSession: expectedSession,
            target: .flags(ids)
        )
    }

    private func performDeletion(_ request: IOSPlotDeletionRequest) {
        switch request.target {
        case let .cards(ids):
            let removedSelection = ids.contains { selection == .card($0) }
            for id in ids {
                _ = store.deletePlotCard(id: id, expectedSession: request.expectedSession)
            }
            if removedSelection {
                selection = nil
            }
        case let .flags(ids):
            let removedSelection = ids.contains { selection == .flag($0) }
            for id in ids {
                _ = store.deleteFlag(id: id, expectedSession: request.expectedSession)
            }
            if removedSelection {
                selection = nil
            }
        }
    }

    private func chapterTitle(for id: ChapterID?) -> String {
        guard let id else { return "章未設定" }
        guard let chapter = store.document.chapters.first(where: { $0.id == id }) else {
            return "章未設定"
        }
        let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "名称未設定の章" : title
    }

    private var deletionRequestIsPresented: Binding<Bool> {
        Binding(
            get: { deletionRequest != nil },
            set: { isPresented in
                if !isPresented {
                    deletionRequest = nil
                }
            }
        )
    }
}

private struct IOSPlotCardRow: View {
    let card: PlotCard
    let chapterTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(NovelDocument.normalizedPlotCardTitle(card.title), systemImage: "rectangle.stack")
                .foregroundStyle(.primary)
                .lineLimit(1)
            if !card.memo.isEmpty {
                Text(card.memo).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            Text(chapterTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(NovelDocument.normalizedPlotCardTitle(card.title))
        .accessibilityValue(chapterTitle)
    }
}

private struct IOSFlagRow: View {
    let flag: Flag
    let chapterTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(NovelDocument.normalizedFlagTitle(flag.title)).foregroundStyle(.primary)
            } icon: {
                Image(systemName: flag.isResolved ? "checkmark.circle.fill" : "flag")
                    .foregroundStyle(flag.isResolved ? FuminiwaColor.leaf.color : FuminiwaColor.warning.color)
            }
            .lineLimit(1)
            if !flag.note.isEmpty {
                Text(flag.note).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            StatusLabel("\(flag.isResolved ? "回収済み" : "未回収")・\(chapterTitle)", systemImage: flag.isResolved ? "checkmark.circle.fill" : "flag", tone: flag.isResolved ? .success : .warning)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(NovelDocument.normalizedFlagTitle(flag.title))
        .accessibilityValue("\(flag.isResolved ? "回収済み" : "未回収")、\(chapterTitle)")
    }
}

private struct IOSPlotDeletionRequest: Identifiable {
    enum Target {
        case cards([PlotCardID])
        case flags([FlagID])
    }

    let id = UUID()
    let expectedSession: WorkspaceSessionToken
    let target: Target

    var title: String {
        switch target {
        case .cards:
            "プロットカードを削除しますか？"
        case .flags:
            "伏線を削除しますか？"
        }
    }

    var message: String {
        switch target {
        case let .cards(ids):
            "選択した\(ids.count)件のプロットカードを削除します。"
        case let .flags(ids):
            "選択した\(ids.count)件の伏線を削除します。"
        }
    }
}
