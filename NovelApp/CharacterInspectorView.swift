import EditorKit
import Foundation
import NovelCore
import SwiftUI

struct CharacterInspectorView: View {
    @Environment(AppState.self) private var appState

    let onSearchQuery: (String) -> Void
    let onAppearanceJump: (CharacterAppearance) -> Void

    @State private var characterPendingDeletion: NovelCore.Character?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: characterSelectionBinding) {
                ForEach(appState.document.characters) { character in
                    CharacterRow(character: character)
                        .tag(character.id)
                        .contextMenu {
                            Button(role: .destructive) {
                                characterPendingDeletion = character
                            } label: {
                                Label("削除", systemImage: "trash")
                            }
                        }
                }
                .onMove { offsets, destination in
                    appState.moveCharacters(fromOffsets: offsets, toOffset: destination)
                }
            }
            .frame(minHeight: 120)

            Divider()

            HStack {
                Button {
                    appState.addCharacter()
                } label: {
                    Label("追加", systemImage: "plus")
                }

                Button(role: .destructive) {
                    if let character = appState.selectedCharacter {
                        characterPendingDeletion = character
                    }
                } label: {
                    Label("削除", systemImage: "trash")
                }
                .disabled(appState.selectedCharacter == nil)

                Spacer()
            }
            .padding(10)

            Divider()

            if appState.selectedCharacter == nil {
                ContentUnavailableView("キャラクターが選択されていません", systemImage: "person")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    CharacterEditor(
                        name: selectedCharacterNameBinding,
                        kana: selectedCharacterKanaBinding,
                        memo: selectedCharacterMemoBinding,
                        colorHex: selectedCharacterColorBinding,
                        onSearchName: {
                            if let query = selectedCharacterSearchQuery {
                                onSearchQuery(query)
                            }
                        },
                        onCommit: {
                            appState.commitCharacterEditing()
                        }
                    )

                    CharacterAppearancesView(
                        appearances: selectedCharacterAppearances,
                        onJump: onAppearanceJump
                    )
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            }
        }
        .confirmationDialog(
            "キャラクターを削除しますか？",
            isPresented: characterDeletionDialogIsPresented,
            presenting: characterPendingDeletion
        ) { character in
            Button("削除", role: .destructive) {
                appState.deleteCharacter(id: character.id)
            }
            Button("キャンセル", role: .cancel) {}
        } message: { character in
            Text("「\(character.name)」を削除します。")
        }
    }

    private var characterSelectionBinding: Binding<CharacterID?> {
        Binding(
            get: { appState.selectedCharacterID },
            set: { appState.selectCharacter($0) }
        )
    }

    private var characterDeletionDialogIsPresented: Binding<Bool> {
        Binding(
            get: { characterPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    characterPendingDeletion = nil
                }
            }
        )
    }

    private var selectedCharacterNameBinding: Binding<String> {
        Binding(
            get: { appState.selectedCharacter?.name ?? "" },
            set: { appState.updateSelectedCharacter(name: $0) }
        )
    }

    private var selectedCharacterKanaBinding: Binding<String> {
        Binding(
            get: { appState.selectedCharacter?.kana ?? "" },
            set: { appState.updateSelectedCharacter(kana: $0) }
        )
    }

    private var selectedCharacterMemoBinding: Binding<String> {
        Binding(
            get: { appState.selectedCharacter?.memo ?? "" },
            set: { appState.updateSelectedCharacter(memo: $0) }
        )
    }

    private var selectedCharacterColorBinding: Binding<String?> {
        Binding(
            get: { appState.selectedCharacter?.colorHex },
            set: { colorHex in
                appState.updateSelectedCharacterColor(colorHex)
            }
        )
    }

    private var selectedCharacterSearchQuery: String? {
        guard let character = appState.selectedCharacter else { return nil }
        let name = NovelDocument.normalizedCharacterName(character.name)
        return name.isEmpty ? nil : name
    }

    private var selectedCharacterAppearances: [CharacterAppearance] {
        guard let character = appState.selectedCharacter else { return [] }
        let queries = appearanceQueries(for: character)
        guard !queries.isEmpty else { return [] }

        return appState.document.chapters.compactMap { chapter in
            for query in queries {
                if let range = TextSearch.find(query: query, in: chapter.content, from: 0, wraps: false) {
                    return CharacterAppearance(
                        chapterID: chapter.id,
                        chapterTitle: chapter.title,
                        query: query,
                        range: range
                    )
                }
            }
            return nil
        }
    }

    private func appearanceQueries(for character: NovelCore.Character) -> [String] {
        var seen: Set<String> = []
        let candidates = [
            NovelDocument.normalizedCharacterName(character.name),
            character.kana.trimmingCharacters(in: .whitespacesAndNewlines)
        ]

        return candidates.compactMap { candidate in
            guard !candidate.isEmpty, !seen.contains(candidate) else { return nil }
            seen.insert(candidate)
            return candidate
        }
    }
}

private struct CharacterRow: View {
    let character: NovelCore.Character

    var body: some View {
        HStack(spacing: 8) {
            CharacterColorSwatch(colorHex: character.colorHex)

            VStack(alignment: .leading, spacing: 2) {
                Text(NovelDocument.normalizedCharacterName(character.name))
                    .lineLimit(1)
                if !character.kana.isEmpty {
                    Text(character.kana)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

private struct CharacterEditor: View {
    @Binding var name: String
    @Binding var kana: String
    @Binding var memo: String
    @Binding var colorHex: String?

    let onSearchName: () -> Void
    let onCommit: () -> Void

    private let colorChoices = ["#C44536", "#2E7D32", "#1565C0", "#6A4C93", "#B7791F"]

    var body: some View {
        Form {
            TextField("名前", text: $name)
                .onSubmit(onCommit)

            TextField("ふりがな", text: $kana)
                .onSubmit(onCommit)

            Picker("カラー", selection: $colorHex) {
                Text("なし")
                    .tag(nil as String?)
                ForEach(colorChoices, id: \.self) { colorHex in
                    HStack {
                        CharacterColorSwatch(colorHex: colorHex)
                        Text(colorHex)
                    }
                    .tag(colorHex as String?)
                }
            }
            .pickerStyle(.menu)

            Button {
                onSearchName()
            } label: {
                Label("この名前で本文検索", systemImage: "magnifyingglass")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("メモ")
                    .foregroundStyle(.secondary)
                TextEditor(text: $memo)
                    .frame(minHeight: 140)
            }
        }
        .formStyle(.grouped)
        .padding(10)
        .onDisappear(perform: onCommit)
    }
}

private struct CharacterAppearancesView: View {
    let appearances: [CharacterAppearance]
    let onJump: (CharacterAppearance) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("登場章")
                .font(.headline)

            if appearances.isEmpty {
                Text("本文中に見つかりません")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appearances) { appearance in
                    Button {
                        onJump(appearance)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(appearance.chapterTitle)
                                    .lineLimit(1)
                                Text("「\(appearance.query)」")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrowshape.turn.up.right")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CharacterColorSwatch: View {
    let colorHex: String?

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .overlay {
                Circle()
                    .stroke(.secondary.opacity(0.35), lineWidth: 1)
            }
    }

    private var color: Color {
        guard let colorHex, let color = Color(hex: colorHex) else {
            return .clear
        }
        return color
    }
}

struct CharacterAppearance: Identifiable {
    let chapterID: ChapterID
    let chapterTitle: String
    let query: String
    let range: NSRange

    var id: String {
        "\(chapterID.rawValue.uuidString)-\(query)-\(range.location)"
    }
}

private extension Color {
    init?(hex: String) {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard trimmed.count == 6, let value = Int(trimmed, radix: 16) else { return nil }

        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0
        self.init(red: red, green: green, blue: blue)
    }
}
