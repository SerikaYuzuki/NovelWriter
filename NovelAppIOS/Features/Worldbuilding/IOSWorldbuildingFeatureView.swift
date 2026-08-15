import NovelCore
import SwiftUI

@MainActor
struct IOSWorldbuildingFeatureView: View {
    let store: IOSDocumentStore
    let expectedSession: IOSDocumentSessionToken?
    @State private var selection: WorldNoteID?

    init(store: IOSDocumentStore) {
        self.store = store
        expectedSession = store.currentDocumentSessionToken
    }

    var body: some View {
        IOSWorldNoteOutlineView(
            store: store,
            selection: $selection,
            expectedSession: expectedSession,
            usesNavigationLinks: true
        )
    }
}

struct IOSWorldNoteOutlineView: View {
    let store: IOSDocumentStore
    @Binding var selection: WorldNoteID?
    let expectedSession: IOSDocumentSessionToken?
    let usesNavigationLinks: Bool

    @State private var deletionRequest: IOSWorldNoteDeletionRequest?

    var body: some View {
        List {
            ForEach(store.document.worldNotes) { note in
                noteRow(note)
            }
            .onDelete(perform: requestDeletion)
            .onMove { offsets, destination in
                guard let expectedSession else { return }
                _ = store.moveWorldNotes(
                    fromOffsets: offsets,
                    toOffset: destination,
                    expectedSession: expectedSession
                )
            }
        }
        .overlay {
            if store.document.worldNotes.isEmpty {
                ContentUnavailableView {
                    Label("世界観ノートがありません", systemImage: "globe.asia.australia")
                } description: {
                    Text("右上の追加ボタンから世界観ノートを追加できます。")
                }
            }
        }
        .navigationTitle("世界観")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    guard let expectedSession else { return }
                    if let id = store.addWorldNote(expectedSession: expectedSession) {
                        selection = id
                    }
                } label: {
                    Label("世界観ノートを追加", systemImage: "plus")
                }
                .disabled(expectedSession == nil)
                .accessibilityIdentifier("ios.worldbuilding.add")
            }

            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .iosWorkChrome(store: store, accessibilityPrefix: "ios.worldbuilding.outline")
        .confirmationDialog(
            "世界観ノートを削除しますか？",
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
    }

    @ViewBuilder
    private func noteRow(_ note: WorldNote) -> some View {
        if usesNavigationLinks {
            NavigationLink {
                IOSWorldNoteDetailView(
                    store: store,
                    noteID: note.id,
                    expectedSession: expectedSession,
                    dismissAfterDeletion: true
                )
            } label: {
                IOSWorldNoteRow(note: note)
            }
        } else {
            Button {
                selection = note.id
            } label: {
                IOSWorldNoteRow(note: note)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selection == note.id ? .isSelected : [])
        }
    }

    private func requestDeletion(at offsets: IndexSet) {
        let ids = offsets.compactMap { index in
            store.document.worldNotes.indices.contains(index) ? store.document.worldNotes[index].id : nil
        }
        guard !ids.isEmpty, let expectedSession else { return }
        deletionRequest = IOSWorldNoteDeletionRequest(expectedSession: expectedSession, noteIDs: ids)
    }

    private func performDeletion(_ request: IOSWorldNoteDeletionRequest) {
        let removesSelection = selection.map(request.noteIDs.contains) ?? false
        for id in request.noteIDs {
            _ = store.deleteWorldNote(id: id, expectedSession: request.expectedSession)
        }
        if removesSelection {
            selection = nil
        }
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

struct IOSWorldNoteDetailView: View {
    let store: IOSDocumentStore
    let noteID: WorldNoteID?
    let expectedSession: IOSDocumentSessionToken?
    var dismissAfterDeletion = false
    var onDeletion: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var deletionRequest: IOSSingleWorldNoteDeletionRequest?

    var body: some View {
        Group {
            if let note = selectedNote {
                noteForm(note)
            } else {
                ContentUnavailableView {
                    Label("世界観ノートが選択されていません", systemImage: "globe.asia.australia")
                } description: {
                    Text("一覧から編集する世界観ノートを選んでください。")
                }
            }
        }
        .confirmationDialog(
            "世界観ノートを削除しますか？",
            isPresented: deletionRequestIsPresented,
            presenting: deletionRequest
        ) { request in
            Button("削除", role: .destructive) {
                let didDelete = store.deleteWorldNote(
                    id: request.noteID,
                    expectedSession: request.expectedSession
                )
                guard didDelete else { return }
                onDeletion()
                if dismissAfterDeletion {
                    dismiss()
                }
            }
            Button("キャンセル", role: .cancel) {}
        } message: { request in
            Text(request.message)
        }
        .iosWorkChrome(store: store, accessibilityPrefix: "ios.worldbuilding.detail")
    }

    private var selectedNote: WorldNote? {
        guard let noteID else { return nil }
        return store.document.worldNotes.first(where: { $0.id == noteID })
    }

    private func noteForm(_ note: WorldNote) -> some View {
        Form {
            Section("世界観ノート") {
                TextField("タイトル", text: noteBinding(note.id, \.title, fallback: ""))
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("ios.worldbuilding.title")

                VStack(alignment: .leading, spacing: 8) {
                    Text("本文")
                        .font(.headline)
                    TextEditor(text: noteBinding(note.id, \.content, fallback: ""))
                        .frame(minHeight: 320)
                        .accessibilityLabel("世界観ノートの本文")
                }
                .padding(.vertical, 8)
            }

            Section {
                Button("世界観ノートを削除", role: .destructive) {
                    guard let expectedSession else { return }
                    deletionRequest = IOSSingleWorldNoteDeletionRequest(
                        expectedSession: expectedSession,
                        noteID: note.id,
                        displayTitle: note.title
                    )
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(displayTitle(note.title))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func noteBinding<Value>(
        _ id: WorldNoteID,
        _ keyPath: WritableKeyPath<WorldNote, Value>,
        fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: {
                store.document.worldNotes.first(where: { $0.id == id })?[keyPath: keyPath] ?? fallback
            },
            set: { newValue in
                guard var note = store.document.worldNotes.first(where: { $0.id == id }) else { return }
                guard let expectedSession else { return }
                note[keyPath: keyPath] = newValue
                _ = store.updateWorldNote(note, expectedSession: expectedSession)
            }
        )
    }

    private func displayTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "無題のノート" : trimmed
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

private struct IOSWorldNoteRow: View {
    let note: WorldNote

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(displayTitle)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text("\(characterCount)字")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(displayTitle)
        .accessibilityValue("\(characterCount)字")
    }

    private var displayTitle: String {
        let trimmed = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "無題のノート" : trimmed
    }

    private var characterCount: Int {
        ManuscriptMetrics.countCharacters(in: note.content)
    }
}

private struct IOSWorldNoteDeletionRequest: Identifiable {
    let id = UUID()
    let expectedSession: IOSDocumentSessionToken
    let noteIDs: [WorldNoteID]

    var message: String {
        "選択した\(noteIDs.count)件の世界観ノートを削除します。"
    }
}

private struct IOSSingleWorldNoteDeletionRequest: Identifiable {
    let id = UUID()
    let expectedSession: IOSDocumentSessionToken
    let noteID: WorldNoteID
    let displayTitle: String

    var message: String {
        let trimmed = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return "「\(trimmed.isEmpty ? "無題のノート" : trimmed)」を削除します。"
    }
}
