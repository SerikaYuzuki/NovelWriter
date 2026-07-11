import AppKit
import NovelCore
import NovelUI
import SwiftUI

struct CharacterListView: View {
    @Environment(AppState.self) private var appState

    @State private var characterPendingDeletion: NovelCore.Character?

    var body: some View {
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
        .overlay {
            if appState.document.characters.isEmpty {
                ContentUnavailableView(
                    "キャラクターがありません",
                    systemImage: "person.2",
                    description: Text("ツールバーまたは登場人物メニューから追加できます。")
                )
            }
        }
        .workbenchGlassOutlineStyle()
        .onDeleteCommand {
            guard let character = appState.selectedCharacter else { return }
            characterPendingDeletion = character
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
}

struct CharacterDetailView: View {
    @Environment(AppState.self) private var appState

    let onAppearanceJump: (CharacterAppearance) -> Void

    var body: some View {
        if appState.selectedCharacter == nil {
            ContentUnavailableView(
                "キャラクターが選択されていません",
                systemImage: "person",
                description: Text("左の一覧から編集するキャラクターを選択してください。")
            )
        } else {
            CharacterSheetView(onAppearanceJump: onAppearanceJump)
        }
    }
}

/// Toolbar-1 以前の入れ子 `NavigationSplitView` 互換ラッパ。新規呼び出しは
/// `CharacterListView` / `CharacterDetailView` を使う。
struct CharacterModeView: View {
    let onAppearanceJump: (CharacterAppearance) -> Void

    var body: some View {
        CharacterDetailView(onAppearanceJump: onAppearanceJump)
    }
}

private struct CharacterSheetView: View {
    @Environment(AppState.self) private var appState

    let onAppearanceJump: (CharacterAppearance) -> Void

    private let roleChoices = ["主人公", "ヒロイン", "ライバル", "敵役", "脇役", "モブ"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                sheetSection("基本") {
                    HStack(alignment: .top, spacing: 12) {
                        WorkbenchLabeledField("役割") {
                            HStack(spacing: 8) {
                                TextField("役割", text: profileBinding(.role))
                                Menu {
                                    ForEach(roleChoices, id: \.self) { role in
                                        Button(role) {
                                            appState.updateSelectedCharacterProfileField(.role, value: role)
                                        }
                                    }
                                } label: {
                                    Label("候補", systemImage: "chevron.down.circle")
                                }
                            }
                        }
                        WorkbenchLabeledField("年齢") {
                            TextField("年齢", text: profileBinding(.age))
                        }
                        WorkbenchLabeledField("性別") {
                            TextField("性別", text: profileBinding(.gender))
                        }
                    }
                }

                sheetSection("口調") {
                    HStack(alignment: .top, spacing: 12) {
                        WorkbenchLabeledField("一人称") {
                            TextField("一人称", text: profileBinding(.firstPerson))
                        }
                        WorkbenchLabeledField("二人称") {
                            TextField("二人称", text: profileBinding(.secondPerson))
                        }
                    }
                    labeledEditor("口調・話し方", text: profileBinding(.speechStyle), minHeight: 90)
                }

                sheetSection("設定") {
                    labeledEditor("外見", text: profileBinding(.appearance), minHeight: 90)
                    labeledEditor("性格", text: profileBinding(.personality), minHeight: 90)
                    labeledEditor("背景・経歴", text: profileBinding(.background), minHeight: 110)
                }

                sheetSection("自由メモ") {
                    labeledEditor("メモ", text: selectedCharacterMemoBinding, minHeight: 140)
                }

                sheetSection("登場章") {
                    CharacterAppearancesView(
                        appearances: selectedCharacterAppearances,
                        onJump: onAppearanceJump
                    )
                }
            }
            .padding(24)
            .frame(maxWidth: 920, alignment: .leading)
        }
        .workbenchGlassChromeStyle()
        .onDisappear {
            appState.commitCharacterEditing()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("名前", text: selectedCharacterNameBinding)
                .font(.title2)
                .textFieldStyle(.plain)
                .onSubmit {
                    appState.commitCharacterEditing()
                }

            HStack(alignment: .top, spacing: 12) {
                WorkbenchLabeledField("ふりがな") {
                    TextField("ふりがな", text: selectedCharacterKanaBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                        .onSubmit {
                            appState.commitCharacterEditing()
                        }
                    }

                colorControls
            }
        }
    }

    private var colorControls: some View {
        HStack(spacing: 12) {
            ColorPicker("カラー", selection: selectedCharacterColorBinding, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 32)

            CharacterColorPresetPicker(
                selectedHex: appState.selectedCharacter?.colorHex,
                onSelect: { hex in
                    appState.updateSelectedCharacterColor(hex)
                }
            )
        }
    }

    private func sheetSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func labeledEditor(_ title: String, text: Binding<String>, minHeight: CGFloat) -> some View {
        WorkbenchLabeledEditor(title) {
            TextEditor(text: text)
                .frame(minHeight: minHeight)
        }
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

    private var selectedCharacterColorBinding: Binding<Color> {
        Binding(
            get: {
                guard let hex = appState.selectedCharacter?.colorHex, let color = Color(hex: hex) else {
                    return Color.accentColor
                }
                return color
            },
            set: { color in
                let nsColor = NSColor(color)
                appState.updateSelectedCharacterColor(nsColor.hexString)
            }
        )
    }

    private func profileBinding(_ field: CharacterProfileField) -> Binding<String> {
        Binding(
            get: {
                guard let character = appState.selectedCharacter else { return "" }
                return switch field {
                case .role:
                    character.role ?? ""
                case .age:
                    character.age ?? ""
                case .gender:
                    character.gender ?? ""
                case .firstPerson:
                    character.firstPerson ?? ""
                case .secondPerson:
                    character.secondPerson ?? ""
                case .speechStyle:
                    character.speechStyle ?? ""
                case .appearance:
                    character.appearance ?? ""
                case .personality:
                    character.personality ?? ""
                case .background:
                    character.background ?? ""
                }
            },
            set: { value in
                appState.updateSelectedCharacterProfileField(field, value: value)
            }
        )
    }

    private var selectedCharacterAppearances: [CharacterAppearance] {
        guard let character = appState.selectedCharacter else { return [] }
        return CharacterAppearanceDetector.appearances(for: character, in: appState.document)
    }
}

private struct CharacterColorPresetPicker: View {
    let selectedHex: String?
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(CharacterColorPreset.hexValues, id: \.self) { hex in
                let fillColor = Color(hex: hex) ?? Color.accentColor
                let strokeColor = selectedHex == hex ? Color.accentColor : Color(nsColor: .separatorColor)

                Button {
                    onSelect(hex)
                } label: {
                    Circle()
                        .fill(fillColor)
                        .frame(width: 16, height: 16)
                        .overlay {
                            Circle()
                                .stroke(strokeColor, lineWidth: 1)
                        }
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help(hex)
            }
        }
    }
}

private struct CharacterAppearancesView: View {
    let appearances: [CharacterAppearance]
    let onJump: (CharacterAppearance) -> Void

    var body: some View {
        if appearances.isEmpty {
            ContentUnavailableView(
                "登場章がありません",
                systemImage: "text.magnifyingglass",
                description: Text("本文に名前かふりがなが含まれると表示されます。")
            )
        } else {
            VStack(alignment: .leading, spacing: 8) {
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
    }
}
