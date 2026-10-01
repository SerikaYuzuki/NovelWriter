import NovelCore
import NovelThumbnail
import NovelUI
import SwiftUI

@MainActor
struct IOSCharacterFeatureView: View {
    let store: IOSDocumentStore
    let expectedSession: IOSDocumentSessionToken?
    @State private var selection: CharacterID?

    init(store: IOSDocumentStore) {
        self.store = store
        expectedSession = store.currentDocumentSessionToken
    }

    var body: some View {
        IOSCharacterOutlineView(
            store: store,
            selection: $selection,
            expectedSession: expectedSession,
            usesNavigationLinks: true
        )
    }
}

struct IOSCharacterOutlineView: View {
    let store: IOSDocumentStore
    @Binding var selection: CharacterID?
    let expectedSession: IOSDocumentSessionToken?
    let usesNavigationLinks: Bool

    @State private var deletionRequest: IOSCharacterDeletionRequest?

    var body: some View {
        List {
            ForEach(store.document.characters) { character in
                characterRow(character)
            }
            .onDelete(perform: requestDeletion)
            .onMove { offsets, destination in
                guard let expectedSession else { return }
                _ = store.moveCharacters(
                    fromOffsets: offsets,
                    toOffset: destination,
                    expectedSession: expectedSession
                )
            }
        }
        .overlay {
            if store.document.characters.isEmpty {
                ContentUnavailableView {
                    Label("登場人物がありません", systemImage: "person.2")
                } actions: {
                    Button("登場人物を追加") {
                        guard let expectedSession else { return }
                        if let id = store.addCharacter(expectedSession: expectedSession) {
                            selection = id
                        }
                    }
                    .disabled(expectedSession == nil)
                }
            }
        }
        .navigationTitle("登場人物")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    guard let expectedSession else { return }
                    if let id = store.addCharacter(expectedSession: expectedSession) {
                        selection = id
                    }
                } label: {
                    Label("登場人物を追加", systemImage: "plus")
                }
                .disabled(expectedSession == nil)
                .accessibilityIdentifier("ios.characters.add")
            }

            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .confirmationDialog(
            "登場人物を削除しますか？",
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
    private func characterRow(_ character: NovelCore.Character) -> some View {
        if usesNavigationLinks {
            NavigationLink {
                IOSCharacterDetailView(
                    store: store,
                    characterID: character.id,
                    expectedSession: expectedSession,
                    dismissAfterDeletion: true
                )
            } label: {
                HStack(spacing: Spacing.small) {
                    ThumbnailImage(data: store.thumbnailData(ThumbnailOwner(.character, character.id.rawValue)),
                                   kind: .character, title: character.name, size: 28, color: character.colorHex.flatMap { Color(hex: $0) })
                        .accessibilityHidden(true)
                    Circle().fill(character.colorHex.flatMap { Color(hex: $0) } ?? FuminiwaColor.textTertiary.color).frame(width: 8, height: 8).accessibilityHidden(true)
                    IOSCharacterRow(character: character)
                }
            }
        } else {
            Button {
                selection = character.id
            } label: {
                HStack(spacing: Spacing.small) {
                    ThumbnailImage(data: store.thumbnailData(ThumbnailOwner(.character, character.id.rawValue)),
                                   kind: .character, title: character.name, size: 28, color: character.colorHex.flatMap { Color(hex: $0) })
                        .accessibilityHidden(true)
                    Circle().fill(character.colorHex.flatMap { Color(hex: $0) } ?? FuminiwaColor.textTertiary.color).frame(width: 8, height: 8).accessibilityHidden(true)
                    IOSCharacterRow(character: character)
                }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selection == character.id ? .isSelected : [])
        }
    }

    private func requestDeletion(at offsets: IndexSet) {
        let ids = offsets.compactMap { index in
            store.document.characters.indices.contains(index) ? store.document.characters[index].id : nil
        }
        guard !ids.isEmpty, let expectedSession else { return }
        deletionRequest = IOSCharacterDeletionRequest(expectedSession: expectedSession, characterIDs: ids)
    }

    private func performDeletion(_ request: IOSCharacterDeletionRequest) {
        let removesSelection = selection.map(request.characterIDs.contains) ?? false
        for id in request.characterIDs {
            _ = store.deleteCharacter(id: id, expectedSession: request.expectedSession)
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

struct IOSCharacterDetailView: View {
    let store: IOSDocumentStore
    let characterID: CharacterID?
    let expectedSession: IOSDocumentSessionToken?
    var dismissAfterDeletion = false
    var onDeletion: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var deletionRequest: IOSSingleCharacterDeletionRequest?

    var body: some View {
        Group {
            if let character = selectedCharacter {
                characterForm(character)
            } else {
                ContentUnavailableView {
                    Label("登場人物が選択されていません", systemImage: "person")
                } description: {
                    if !store.document.characters.isEmpty {
                        Text("一覧から登場人物を選択してください。")
                    }
                }
            }
        }
        .confirmationDialog(
            "登場人物を削除しますか？",
            isPresented: deletionRequestIsPresented,
            presenting: deletionRequest
        ) { request in
            Button("削除", role: .destructive) {
                let didDelete = store.deleteCharacter(
                    id: request.characterID,
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
    }

    private var selectedCharacter: NovelCore.Character? {
        guard let characterID else { return nil }
        return store.document.characters.first(where: { $0.id == characterID })
    }

    private func characterForm(_ character: NovelCore.Character) -> some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: Spacing.group) {
                    IOSThumbnailEditor(store: store, owner: ThumbnailOwner(.character, character.id.rawValue), title: character.name, color: character.colorHex.flatMap { Color(hex: $0) })
                    VStack(alignment: .leading, spacing: Spacing.small) {
                        Text(NovelDocument.normalizedCharacterName(character.name)).font(.title2.weight(.semibold))
                        if !character.kana.isEmpty {
                            Text(character.kana).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if let role = character.role, !role.isEmpty {
                            Text(role).font(.caption).padding(Spacing.extraSmall)
                                .background(FuminiwaColor.accentMuted.color, in: RoundedRectangle(cornerRadius: Radius.chip))
                        }
                    }
                }
            }
            Section("基本情報") {
                TextField("名前", text: characterBinding(character.id, \.name, fallback: ""))
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("ios.character.name")
                TextField("ふりがな", text: characterBinding(character.id, \.kana, fallback: ""))
                    .textInputAutocapitalization(.never)
                TextField("役割", text: optionalCharacterBinding(character.id, \.role))
                TextField("年齢", text: optionalCharacterBinding(character.id, \.age))
                TextField("性別", text: optionalCharacterBinding(character.id, \.gender))
            }

            Section("人物の色") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))]) {
                    ForEach(CharacterColorPreset.hexValues, id: \.self) { hex in
                        Button {
                            var updated = character
                            updated.colorHex = hex
                            guard let expectedSession else { return }
                            _ = store.updateCharacter(updated, expectedSession: expectedSession)
                        } label: {
                            Circle().fill(Color(hex: hex) ?? FuminiwaColor.sunken.color)
                                .frame(width: 28, height: 28)
                                .overlay(Circle().strokeBorder(character.colorHex == hex ? FuminiwaColor.accent.color : FuminiwaColor.separator.color, lineWidth: character.colorHex == hex ? 2 : 0.5))
                                .overlay {
                                    if character.colorHex == hex {
                                        Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                                    }
                                }
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .help(CharacterColorPreset.name(for: hex))
                        .accessibilityLabel(CharacterColorPreset.name(for: hex))
                        .accessibilityAddTraits(character.colorHex == hex ? .isSelected : [])
                    }
                }
            }
            Section("話し方") {
                TextField("一人称", text: optionalCharacterBinding(character.id, \.firstPerson))
                TextField("二人称", text: optionalCharacterBinding(character.id, \.secondPerson))
                VStack(alignment: .leading, spacing: 8) {
                    Text("口調・話し方")
                        .font(.headline)
                    TextEditor(text: optionalCharacterBinding(character.id, \.speechStyle))
                        .frame(minHeight: 96)
                        .accessibilityLabel("口調・話し方")
                }
                .padding(.vertical, 8)
            }

            Section("設定") {
                characterEditor("外見", id: character.id, keyPath: \.appearance)
                characterEditor("性格", id: character.id, keyPath: \.personality)
                characterEditor("背景・経歴", id: character.id, keyPath: \.background)
            }

            Section("自由メモ") {
                TextEditor(text: characterBinding(character.id, \.memo, fallback: ""))
                    .frame(minHeight: 128)
                    .accessibilityLabel("自由メモ")
            }

            Section {
                Button("登場人物を削除", role: .destructive) {
                    guard let expectedSession else { return }
                    deletionRequest = IOSSingleCharacterDeletionRequest(
                        expectedSession: expectedSession,
                        characterID: character.id,
                        displayName: character.name
                    )
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(FuminiwaColor.paper.color)
        .navigationTitle(NovelDocument.normalizedCharacterName(character.name))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func characterEditor(
        _ title: String,
        id: CharacterID,
        keyPath: WritableKeyPath<NovelCore.Character, String?>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            TextEditor(text: optionalCharacterBinding(id, keyPath))
                .frame(minHeight: 96)
                .accessibilityLabel(title)
        }
        .padding(.vertical, 8)
    }

    private func characterBinding<Value>(
        _ id: CharacterID,
        _ keyPath: WritableKeyPath<NovelCore.Character, Value>,
        fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: {
                store.document.characters.first(where: { $0.id == id })?[keyPath: keyPath] ?? fallback
            },
            set: { newValue in
                guard var character = store.document.characters.first(where: { $0.id == id }) else { return }
                guard let expectedSession else { return }
                character[keyPath: keyPath] = newValue
                _ = store.updateCharacter(character, expectedSession: expectedSession)
            }
        )
    }

    private func optionalCharacterBinding(
        _ id: CharacterID,
        _ keyPath: WritableKeyPath<NovelCore.Character, String?>
    ) -> Binding<String> {
        Binding(
            get: {
                store.document.characters.first(where: { $0.id == id })?[keyPath: keyPath] ?? ""
            },
            set: { newValue in
                guard var character = store.document.characters.first(where: { $0.id == id }) else { return }
                guard let expectedSession else { return }
                character[keyPath: keyPath] = newValue.isEmpty ? nil : newValue
                _ = store.updateCharacter(character, expectedSession: expectedSession)
            }
        )
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

private struct IOSCharacterRow: View {
    let character: NovelCore.Character

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(NovelDocument.normalizedCharacterName(character.name))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if !detailText.isEmpty {
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(NovelDocument.normalizedCharacterName(character.name))
        .accessibilityValue(detailText)
    }

    private var detailText: String {
        [character.kana, character.role ?? ""]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "・")
    }
}

private struct IOSCharacterDeletionRequest: Identifiable {
    let id = UUID()
    let expectedSession: IOSDocumentSessionToken
    let characterIDs: [CharacterID]

    var message: String {
        "選択した\(characterIDs.count)人を削除します。"
    }
}

private struct IOSSingleCharacterDeletionRequest: Identifiable {
    let id = UUID()
    let expectedSession: IOSDocumentSessionToken
    let characterID: CharacterID
    let displayName: String

    var message: String {
        "「\(NovelDocument.normalizedCharacterName(displayName))」を削除します。"
    }
}
