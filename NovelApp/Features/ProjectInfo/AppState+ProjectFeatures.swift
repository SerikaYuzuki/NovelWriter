import Foundation
import NovelCore
import NovelWorkspace

extension AppState {
    // MARK: - 登場人物

    /// 登場人物を追加し、追加した人物を選択状態にする。
    func addCharacter() {
        guard let id = projectFeatureCommands(.flushNow).addCharacter(expectedSession: documentSessionToken) else { return }
        selectedCharacterID = id
    }

    /// 登場人物を選択する。
    func selectCharacter(_ id: CharacterID?) {
        guard permitsDocumentInteraction else { return }
        selectedCharacterID = id
    }

    /// 選択中の登場人物を更新する。
    func updateSelectedCharacter(
        name: String? = nil,
        kana: String? = nil,
        memo: String? = nil,
        colorHex: String? = nil,
        role: String? = nil,
        age: String? = nil,
        gender: String? = nil,
        firstPerson: String? = nil,
        secondPerson: String? = nil,
        speechStyle: String? = nil,
        appearance: String? = nil,
        personality: String? = nil,
        background: String? = nil
    ) {
        guard var next = selectedCharacter else { return }
        next.name = name ?? next.name
        next.kana = kana ?? next.kana
        next.memo = memo ?? next.memo
        next.colorHex = colorHex ?? next.colorHex
        next.role = role ?? next.role
        next.age = age ?? next.age
        next.gender = gender ?? next.gender
        next.firstPerson = firstPerson ?? next.firstPerson
        next.secondPerson = secondPerson ?? next.secondPerson
        next.speechStyle = speechStyle ?? next.speechStyle
        next.appearance = appearance ?? next.appearance
        next.personality = personality ?? next.personality
        next.background = background ?? next.background
        projectFeatureCommands(.debounced).updateCharacter(next, expectedSession: documentSessionToken)
    }

    /// Optional な登場人物シート項目を更新する。空文字は `nil` として保存する。
    func updateSelectedCharacterProfile(
        role: String? = nil,
        age: String? = nil,
        gender: String? = nil,
        firstPerson: String? = nil,
        secondPerson: String? = nil,
        speechStyle: String? = nil,
        appearance: String? = nil,
        personality: String? = nil,
        background: String? = nil
    ) {
        guard permitsDocumentInteraction else { return }
        updateSelectedCharacter(
            role: role.map(Self.nilIfBlank(_:)) ?? selectedCharacter?.role,
            age: age.map(Self.nilIfBlank(_:)) ?? selectedCharacter?.age,
            gender: gender.map(Self.nilIfBlank(_:)) ?? selectedCharacter?.gender,
            firstPerson: firstPerson.map(Self.nilIfBlank(_:)) ?? selectedCharacter?.firstPerson,
            secondPerson: secondPerson.map(Self.nilIfBlank(_:)) ?? selectedCharacter?.secondPerson,
            speechStyle: speechStyle.map(Self.nilIfBlank(_:)) ?? selectedCharacter?.speechStyle,
            appearance: appearance.map(Self.nilIfBlank(_:)) ?? selectedCharacter?.appearance,
            personality: personality.map(Self.nilIfBlank(_:)) ?? selectedCharacter?.personality,
            background: background.map(Self.nilIfBlank(_:)) ?? selectedCharacter?.background
        )
    }

    func updateSelectedCharacterProfileField(_ field: CharacterProfileField, value: String) {
        guard permitsDocumentInteraction else { return }
        guard var current = selectedCharacter else { return }
        let normalized = Self.nilIfBlank(value)

        switch field {
        case .role:
            current.role = normalized
        case .age:
            current.age = normalized
        case .gender:
            current.gender = normalized
        case .firstPerson:
            current.firstPerson = normalized
        case .secondPerson:
            current.secondPerson = normalized
        case .speechStyle:
            current.speechStyle = normalized
        case .appearance:
            current.appearance = normalized
        case .personality:
            current.personality = normalized
        case .background:
            current.background = normalized
        }

        if !projectFeatureCommands(.debounced).updateCharacter(current, expectedSession: documentSessionToken),
           permitsLocalMutation {
            // This field editor also marked unchanged values dirty before the shared port.
            markChanged(policy: .debounced)
        }
    }

    /// 選択中の登場人物カラーを更新する。`nil` はカラーなしを表す。
    func updateSelectedCharacterColor(_ colorHex: String?) {
        guard var next = selectedCharacter else { return }
        next.colorHex = colorHex
        projectFeatureCommands(.debounced).updateCharacter(next, expectedSession: documentSessionToken)
    }

    /// 登場人物名の編集確定時に、空名を正規化して即時保存へ寄せる。
    func commitCharacterEditing() {
        guard permitsDocumentInteraction else { return }
        for var character in document.characters {
            character.name = NovelDocument.normalizedCharacterName(character.name)
            projectFeatureCommands(.debounced).updateCharacter(character, expectedSession: documentSessionToken)
        }
        flushSaveImmediately()
    }

    /// 登場人物を削除する。
    @discardableResult
    func deleteCharacter(id: CharacterID, expectedSession: WorkspaceSessionToken? = nil) -> Bool {
        guard let originalIndex = document.characters.firstIndex(where: { $0.id == id }),
              projectFeatureCommands(.flushNow).deleteCharacter(
                  id: id,
                  expectedSession: expectedSession ?? documentSessionToken
              ) else { return false }
        if selectedCharacterID == id {
            let fallbackIndex = min(originalIndex, document.characters.count - 1)
            selectedCharacterID = document.characters.indices.contains(fallbackIndex) ? document
                .characters[fallbackIndex].id : nil
        }
        return true
    }

    /// 登場人物を並べ替える。
    func moveCharacters(fromOffsets: IndexSet, toOffset: Int) {
        projectFeatureCommands(.flushNow).moveCharacters(
            fromOffsets: fromOffsets,
            toOffset: toOffset,
            expectedSession: documentSessionToken
        )
    }

    // MARK: - プロットカード

    /// プロットカードを追加し、追加したカードを選択状態にする。
    func addPlotCard(chapterID: ChapterID? = nil) {
        guard let id = projectFeatureCommands(.flushNow).addPlotCard(
            chapterID: chapterID,
            expectedSession: documentSessionToken
        ) else { return }
        selectedPlotCardID = id
    }

    /// プロットカードを選択する。
    func selectPlotCard(_ id: PlotCardID?) {
        guard permitsDocumentInteraction else { return }
        selectedPlotCardID = id
    }

    /// 選択中のプロットカードを更新する。
    func updateSelectedPlotCard(title: String? = nil, memo: String? = nil, chapterID: ChapterID? = nil) {
        guard var next = selectedPlotCard else { return }
        next.title = title ?? next.title
        next.memo = memo ?? next.memo
        next.chapterID = chapterID ?? next.chapterID
        projectFeatureCommands(.debounced).updatePlotCard(next, expectedSession: documentSessionToken)
    }

    /// 選択中のプロットカードの章紐付けを更新する。`nil` は未紐付けを表す。
    func updateSelectedPlotCardChapter(_ chapterID: ChapterID?) {
        guard var next = selectedPlotCard else { return }
        next.chapterID = chapterID
        projectFeatureCommands(.debounced).updatePlotCard(next, expectedSession: documentSessionToken)
    }

    /// プロットカードタイトルの編集確定時に、空タイトルを正規化して即時保存へ寄せる。
    func commitPlotCardEditing() {
        guard permitsDocumentInteraction else { return }
        for var card in document.plotCards {
            card.title = NovelDocument.normalizedPlotCardTitle(card.title)
            projectFeatureCommands(.debounced).updatePlotCard(card, expectedSession: documentSessionToken)
        }
        flushSaveImmediately()
    }

    /// プロットカードを削除する。
    @discardableResult
    func deletePlotCard(id: PlotCardID, expectedSession: WorkspaceSessionToken? = nil) -> Bool {
        guard let originalIndex = document.plotCards.firstIndex(where: { $0.id == id }),
              projectFeatureCommands(.flushNow).deletePlotCard(
                  id: id,
                  expectedSession: expectedSession ?? documentSessionToken
              ) else { return false }
        if selectedPlotCardID == id {
            let fallbackIndex = min(originalIndex, document.plotCards.count - 1)
            selectedPlotCardID = document.plotCards.indices.contains(fallbackIndex) ? document.plotCards[fallbackIndex]
                .id : nil
        }
        return true
    }

    /// プロットカードを並べ替える。
    func movePlotCards(fromOffsets: IndexSet, toOffset: Int) {
        projectFeatureCommands(.flushNow).movePlotCards(
            fromOffsets: fromOffsets,
            toOffset: toOffset,
            expectedSession: documentSessionToken
        )
    }

    /// プロットカードを章レーン内/レーン間で移動する。
    func movePlotCard(id: PlotCardID, toChapter chapterID: ChapterID?, before targetID: PlotCardID? = nil) {
        projectFeatureCommands(.flushNow).movePlotCard(
            id: id,
            toChapter: chapterID,
            before: targetID,
            expectedSession: documentSessionToken
        )
    }

    /// Plot Outlineへのdropとしてカードの所属先を変更する。
    /// 存在しないカード／章、および現在と同じ所属先へのdropは拒否する。
    @discardableResult
    func movePlotCardFromOutline(id: PlotCardID, to selection: PlotOutlineSelection) -> Bool {
        guard permitsDocumentInteraction else { return false }
        if case let .chapter(chapterID) = selection, chapterID != selectedChapterID {
            guard permitsDocumentInteraction else { return false }
        }
        guard let card = document.plotCards.first(where: { $0.id == id }) else { return false }

        let destinationChapterID: ChapterID?
        switch selection {
        case .unassigned:
            destinationChapterID = nil
        case let .chapter(chapterID):
            guard document.chapters.contains(where: { $0.id == chapterID }) else { return false }
            destinationChapterID = chapterID
        }

        guard card.chapterID != destinationChapterID else { return false }

        guard projectFeatureCommands(.flushNow).movePlotCard(
            id: id,
            toChapter: destinationChapterID,
            expectedSession: documentSessionToken
        ) else { return false }
        selectedPlotCardID = id
        plotOutlineSelection = selection
        if let destinationChapterID {
            setSelection(chapterID: destinationChapterID, episodeID: preferredEpisodeID(in: destinationChapterID))
        }
        return true
    }

    // MARK: - 伏線

    /// 伏線を追加し、追加した伏線を選択状態にする。
    func addFlag() {
        guard let id = projectFeatureCommands(.flushNow).addFlag(
            plantedChapterID: selectedChapterID,
            expectedSession: documentSessionToken
        ) else { return }
        selectedFlagID = id
    }

    /// 伏線を選択する。
    func selectFlag(_ id: FlagID?) {
        guard permitsDocumentInteraction else { return }
        selectedFlagID = id
    }

    /// 選択中の伏線を更新する。
    func updateSelectedFlag(title: String? = nil, note: String? = nil) {
        guard var next = selectedFlag else { return }
        next.title = title ?? next.title
        next.note = note ?? next.note
        projectFeatureCommands(.debounced).updateFlag(next, expectedSession: documentSessionToken)
    }

    /// 選択中の伏線の章紐付けを更新する。
    func updateSelectedFlagChapters(plantedChapterID: ChapterID? = nil, resolvedChapterID: ChapterID? = nil) {
        guard var next = selectedFlag else { return }
        next.plantedChapterID = plantedChapterID ?? next.plantedChapterID
        next.resolvedChapterID = resolvedChapterID ?? next.resolvedChapterID
        projectFeatureCommands(.debounced).updateFlag(next, expectedSession: documentSessionToken)
    }

    /// 選択中の伏線の張った章を更新する。`nil` は未設定を表す。
    func updateSelectedFlagPlantedChapter(_ chapterID: ChapterID?) {
        guard var next = selectedFlag else { return }
        next.plantedChapterID = chapterID
        projectFeatureCommands(.debounced).updateFlag(next, expectedSession: documentSessionToken)
    }

    /// 選択中の伏線の回収章を更新する。`nil` は未設定を表す。
    func updateSelectedFlagResolvedChapter(_ chapterID: ChapterID?) {
        guard var next = selectedFlag else { return }
        next.resolvedChapterID = chapterID
        projectFeatureCommands(.debounced).updateFlag(next, expectedSession: documentSessionToken)
    }

    /// 選択中の伏線の回収状態を反転する。
    func toggleSelectedFlagResolved() {
        guard var next = selectedFlag else { return }
        next.isResolved.toggle()
        next.resolvedChapterID = next.isResolved ? selectedChapterID : nil
        projectFeatureCommands(.flushNow).updateFlag(next, expectedSession: documentSessionToken)
    }

    /// 伏線タイトルの編集確定時に、空タイトルを正規化して即時保存へ寄せる。
    func commitFlagEditing() {
        guard permitsDocumentInteraction else { return }
        for var flag in document.flags {
            flag.title = NovelDocument.normalizedFlagTitle(flag.title)
            projectFeatureCommands(.debounced).updateFlag(flag, expectedSession: documentSessionToken)
        }
        flushSaveImmediately()
    }

    /// 伏線を削除する。
    @discardableResult
    func deleteFlag(id: FlagID, expectedSession: WorkspaceSessionToken? = nil) -> Bool {
        guard let originalIndex = document.flags.firstIndex(where: { $0.id == id }),
              projectFeatureCommands(.flushNow).deleteFlag(
                  id: id,
                  expectedSession: expectedSession ?? documentSessionToken
              ) else { return false }
        if selectedFlagID == id {
            let fallbackIndex = min(originalIndex, document.flags.count - 1)
            selectedFlagID = document.flags.indices.contains(fallbackIndex) ? document.flags[fallbackIndex].id : nil
        }
        return true
    }

    /// 伏線を並べ替える。
    func moveFlags(fromOffsets: IndexSet, toOffset: Int) {
        projectFeatureCommands(.flushNow).moveFlags(
            fromOffsets: fromOffsets,
            toOffset: toOffset,
            expectedSession: documentSessionToken
        )
    }
}
