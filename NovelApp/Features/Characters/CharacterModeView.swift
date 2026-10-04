import AppKit
import NovelCore
import NovelTextAnalysis
import NovelThumbnail
import NovelUI
import SwiftUI

struct CharacterListView: View {
    @Environment(AppState.self) private var appState

    @State private var characterPendingDeletion: SessionBoundValue<NovelCore.Character>?

    var body: some View {
        List(selection: characterSelectionBinding) {
            ForEach(sessionBoundCharacters) { item in
                CharacterRow(character: item.value, thumbnailData: appState.thumbnailData(ThumbnailOwner(.character, item.value.id.rawValue)))
                    .contextMenu {
                        Button(role: .destructive) {
                            characterPendingDeletion = item
                        } label: {
                            Label("削除", systemImage: "trash")
                        }
                    }
                    .tag(item.value.id)
            }
            .onMove { offsets, destination in
                appState.moveCharacters(fromOffsets: offsets, toOffset: destination)
            }
        }
        .overlay {
            if appState.document.characters.isEmpty {
                ContentUnavailableView {
                    Label("登場人物がありません", systemImage: "person.2")
                } actions: {
                    Button("登場人物を追加") { appState.addCharacter() }
                        .disabled(!appState.permitsDocumentInteraction)
                }
            }
        }
        .workbenchGlassOutlineStyle()
        .onDeleteCommand {
            guard let character = appState.selectedCharacter else { return }
            characterPendingDeletion = SessionBoundValue(
                value: character,
                session: appState.documentSessionToken
            )
        }
        .confirmationDialog(
            "登場人物を削除しますか？",
            isPresented: characterDeletionDialogIsPresented,
            presenting: characterPendingDeletion
        ) { request in
            Button("削除", role: .destructive) {
                appState.deleteCharacter(id: request.value.id, expectedSession: request.session)
            }
            Button("キャンセル", role: .cancel) {}
        } message: { request in
            Text("「\(request.value.name)」を削除します。")
        }
    }

    private var sessionBoundCharacters: [SessionBoundValue<NovelCore.Character>] {
        let session = appState.documentSessionToken
        return appState.document.characters.map {
            SessionBoundValue(value: $0, session: session)
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
            ContentUnavailableView {
                Label("登場人物が選択されていません", systemImage: "person")
            } description: {
                if !appState.document.characters.isEmpty {
                    Text("左の一覧から登場人物を選択してください。")
                }
            }
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

    @State private var appearanceSession = CharacterAppearanceSession()
    private let roleChoices = ["主人公", "ヒロイン", "ライバル", "敵役", "脇役", "モブ"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                sheetSection("基本") {
                    HStack(alignment: .top, spacing: 12) {
                        WorkbenchLabeledField("役割") {
                            HStack(spacing: 8) {
                                TextField("役割", text: profileBinding(.role), axis: .vertical).lineLimit(1 ... 3)
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
                            TextField("年齢", text: profileBinding(.age), axis: .vertical).lineLimit(1 ... 3)
                        }
                        WorkbenchLabeledField("性別") {
                            TextField("性別", text: profileBinding(.gender), axis: .vertical).lineLimit(1 ... 3)
                        }
                    }
                }

                sheetSection("口調") {
                    HStack(alignment: .top, spacing: 12) {
                        WorkbenchLabeledField("一人称") {
                            TextField("一人称", text: profileBinding(.firstPerson), axis: .vertical).lineLimit(1 ... 3)
                        }
                        WorkbenchLabeledField("二人称") {
                            TextField("二人称", text: profileBinding(.secondPerson), axis: .vertical).lineLimit(1 ... 3)
                        }
                    }
                    labeledEditor("口調・話し方", text: profileBinding(.speechStyle))
                }

                sheetSection("設定") {
                    labeledEditor("外見", text: profileBinding(.appearance))
                    labeledEditor("性格", text: profileBinding(.personality))
                    labeledEditor("背景・経歴", text: profileBinding(.background))
                }

                sheetSection("自由メモ") {
                    labeledEditor("メモ", text: selectedCharacterMemoBinding)
                }

                sheetSection("登場章") {
                    CharacterAppearancesView(
                        appearances: appearanceSession.appearances,
                        isLoading: appearanceSession.isLoading,
                        onJump: onAppearanceJump
                    )
                }
            }
            .padding(24)
            .frame(maxWidth: 920, alignment: .leading)
        }
        .background(FuminiwaColor.paper.color)
        .onAppear { appearanceSession.setVisible(true, character: appState.selectedCharacter, document: appState.document) }
        .onChange(of: appState.documentChangeRevision) { _, _ in refreshAppearances() }
        .onChange(of: appState.selectedCharacter) { _, _ in refreshAppearances() }
        .onChange(of: appState.workSearchScope) { _, _ in refreshAppearances() }
        .onDisappear {
            appearanceSession.setVisible(false, character: appState.selectedCharacter, document: appState.document)
            appState.commitCharacterEditing()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            HStack(alignment: .top, spacing: Spacing.group) {
                if let character = appState.selectedCharacter {
                    MacThumbnailEditor(owner: ThumbnailOwner(.character, character.id.rawValue), title: character.name,
                                       color: character.colorHex.flatMap { Color(hex: $0) })
                }
                VStack(alignment: .leading, spacing: Spacing.small) {
                    TextField("名前", text: selectedCharacterNameBinding, axis: .vertical).lineLimit(1 ... 3)
                        .font(.title2.weight(.semibold)).textFieldStyle(.plain)
                        .foregroundStyle(FuminiwaColor.textPrimary.color)
                        .onSubmit { appState.commitCharacterEditing() }
                    WorkbenchLabeledField("ふりがな") {
                        TextField("ふりがな", text: selectedCharacterKanaBinding, axis: .vertical).lineLimit(1 ... 3)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                            .onSubmit { appState.commitCharacterEditing() }
                    }
                    if let role = appState.selectedCharacter?.role, !role.isEmpty {
                        Text(role).font(.caption).padding(Spacing.extraSmall)
                            .background(FuminiwaColor.accentMuted.color, in: RoundedRectangle(cornerRadius: Radius.chip))
                    }
                }
            }
            HStack {
                colorControls
                Spacer()
                Menu {
                    Button("本文の名前を置換…") {
                        let name = appState.selectedCharacter?.name ?? ""
                        Task { await appState.presentWorkSearch(query: name) }
                    }
                } label: { Label("人物の操作", systemImage: "ellipsis.circle") }
            }
        }
    }

    private var colorControls: some View {
        HStack(spacing: 12) {
            ColorPicker("カスタムカラー", selection: selectedCharacterColorBinding, supportsOpacity: false)
                .fixedSize()

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
        .padding(Spacing.group)
        .background(FuminiwaColor.surface.color, in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(FuminiwaColor.separator.color, lineWidth: 0.5))
    }

    private func labeledEditor(_ title: String, text: Binding<String>) -> some View {
        WorkbenchLabeledEditor(title) {
            TextEditor(text: text)
                .frame(minHeight: 160, idealHeight: 240)
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

    private func refreshAppearances() {
        appearanceSession.refresh(character: appState.selectedCharacter, document: appState.document)
    }
}

private struct CharacterColorPresetPicker: View {
    let selectedHex: String?
    let onSelect: (String?) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button { onSelect(nil) } label: {
                Circle().strokeBorder(FuminiwaColor.textSecondary.color, lineWidth: 1)
                    .overlay(Image(systemName: "line.diagonal").font(.caption))
                    .frame(width: 16, height: 16)
                    .overlay {
                        if selectedHex == nil {
                            Circle().stroke(FuminiwaColor.accent.color, lineWidth: 2).padding(-3)
                            Image(systemName: "checkmark").font(.caption2.bold())
                        }
                    }
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("色なし")
            .accessibilityLabel("色なし")
            .accessibilityAddTraits(selectedHex == nil ? .isSelected : [])
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
                                .stroke(strokeColor, lineWidth: selectedHex == hex ? 2 : 0.5)
                        }
                        .overlay {
                            if selectedHex == hex {
                                Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.white)
                            }
                        }
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(CharacterColorPreset.name(for: hex))
                .accessibilityLabel(CharacterColorPreset.name(for: hex))
                .accessibilityAddTraits(selectedHex == hex ? .isSelected : [])
            }
        }
    }
}

private struct CharacterAppearancesView: View {
    let appearances: [CharacterAppearance]
    let isLoading: Bool
    let onJump: (CharacterAppearance) -> Void

    var body: some View {
        if isLoading {
            ProgressView("登場を確認中")
        } else if appearances.isEmpty {
            Text("本文にまだ登場していません").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(CharacterAppearanceDetector.summary(appearances)).font(.caption).foregroundStyle(.secondary)
                ForEach(appearances) { appearance in
                    Button {
                        onJump(appearance)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(appearance.chapterTitle) · \(appearance.episodeTitle)")
                                    .lineLimit(1)
                                Text("\(appearance.count)回")
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
