import AppKit
import EditorKit
import Foundation
import NovelCore
import NovelSync

extension AppState {
    // MARK: - 登場人物

    /// 登場人物を追加し、追加した人物を選択状態にする。
    func addCharacter() {
        guard permitsDocumentInteraction else { return }
        let newID = document.addCharacter(name: "名無し")
        selectedCharacterID = newID
        saveCoordinator.markDirty()
        flushSaveImmediately()
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
        guard permitsDocumentInteraction else { return }
        guard let selectedCharacterID, let current = selectedCharacter else { return }
        let nextName = name ?? current.name
        let nextKana = kana ?? current.kana
        let nextMemo = memo ?? current.memo
        let nextColorHex = colorHex ?? current.colorHex
        let nextRole = role ?? current.role
        let nextAge = age ?? current.age
        let nextGender = gender ?? current.gender
        let nextFirstPerson = firstPerson ?? current.firstPerson
        let nextSecondPerson = secondPerson ?? current.secondPerson
        let nextSpeechStyle = speechStyle ?? current.speechStyle
        let nextAppearance = appearance ?? current.appearance
        let nextPersonality = personality ?? current.personality
        let nextBackground = background ?? current.background

        guard current.name != nextName || current.kana != nextKana || current.memo != nextMemo ||
            current.colorHex != nextColorHex || current.role != nextRole || current.age != nextAge ||
            current.gender != nextGender || current.firstPerson != nextFirstPerson ||
            current.secondPerson != nextSecondPerson || current.speechStyle != nextSpeechStyle ||
            current.appearance != nextAppearance || current.personality != nextPersonality ||
            current.background != nextBackground else {
            return
        }

        document.updateCharacter(
            id: selectedCharacterID,
            name: nextName,
            kana: nextKana,
            memo: nextMemo,
            colorHex: nextColorHex,
            role: nextRole,
            age: nextAge,
            gender: nextGender,
            firstPerson: nextFirstPerson,
            secondPerson: nextSecondPerson,
            speechStyle: nextSpeechStyle,
            appearance: nextAppearance,
            personality: nextPersonality,
            background: nextBackground
        )
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
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

        document.updateCharacter(
            id: current.id,
            name: current.name,
            kana: current.kana,
            memo: current.memo,
            colorHex: current.colorHex,
            role: current.role,
            age: current.age,
            gender: current.gender,
            firstPerson: current.firstPerson,
            secondPerson: current.secondPerson,
            speechStyle: current.speechStyle,
            appearance: current.appearance,
            personality: current.personality,
            background: current.background
        )
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 選択中の登場人物カラーを更新する。`nil` はカラーなしを表す。
    func updateSelectedCharacterColor(_ colorHex: String?) {
        guard permitsDocumentInteraction else { return }
        guard let selectedCharacterID, let current = selectedCharacter else { return }
        guard current.colorHex != colorHex else { return }

        document.updateCharacter(
            id: selectedCharacterID,
            name: current.name,
            kana: current.kana,
            memo: current.memo,
            colorHex: colorHex,
            role: current.role,
            age: current.age,
            gender: current.gender,
            firstPerson: current.firstPerson,
            secondPerson: current.secondPerson,
            speechStyle: current.speechStyle,
            appearance: current.appearance,
            personality: current.personality,
            background: current.background
        )
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 登場人物名の編集確定時に、空名を正規化して即時保存へ寄せる。
    func commitCharacterEditing() {
        guard permitsDocumentInteraction else { return }
        for character in document.characters {
            let normalizedName = NovelDocument.normalizedCharacterName(character.name)
            if character.name != normalizedName {
                document.updateCharacter(
                    id: character.id,
                    name: normalizedName,
                    kana: character.kana,
                    memo: character.memo,
                    colorHex: character.colorHex,
                    role: character.role,
                    age: character.age,
                    gender: character.gender,
                    firstPerson: character.firstPerson,
                    secondPerson: character.secondPerson,
                    speechStyle: character.speechStyle,
                    appearance: character.appearance,
                    personality: character.personality,
                    background: character.background
                )
                saveCoordinator.markDirty()
            }
        }
        flushSaveImmediately()
    }

    /// 登場人物を削除する。
    @discardableResult
    func deleteCharacter(id: CharacterID, expectedSession: DocumentSessionToken? = nil) -> Bool {
        guard permitsMutation(expectedSession: expectedSession) else { return false }
        guard let originalIndex = document.characters.firstIndex(where: { $0.id == id }) else { return false }
        guard document.removeCharacter(id: id) != nil else { return false }

        if selectedCharacterID == id {
            let fallbackIndex = min(originalIndex, document.characters.count - 1)
            selectedCharacterID = document.characters.indices.contains(fallbackIndex) ?
                document.characters[fallbackIndex].id : nil
        }

        saveCoordinator.markDirty()
        flushSaveImmediately()
        return true
    }

    /// 登場人物を並べ替える。
    func moveCharacters(fromOffsets: IndexSet, toOffset: Int) {
        guard permitsDocumentInteraction else { return }
        document.moveCharacters(fromOffsets: fromOffsets, toOffset: toOffset)
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    // MARK: - プロットカード

    /// プロットカードを追加し、追加したカードを選択状態にする。
    func addPlotCard(chapterID: ChapterID? = nil) {
        guard permitsDocumentInteraction else { return }
        let newID = document.addPlotCard(title: "新しいカード", chapterID: chapterID)
        selectedPlotCardID = newID
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// プロットカードを選択する。
    func selectPlotCard(_ id: PlotCardID?) {
        guard permitsDocumentInteraction else { return }
        selectedPlotCardID = id
    }

    /// 選択中のプロットカードを更新する。
    func updateSelectedPlotCard(title: String? = nil, memo: String? = nil, chapterID: ChapterID? = nil) {
        guard permitsDocumentInteraction else { return }
        guard let selectedPlotCardID, let current = selectedPlotCard else { return }
        let nextTitle = title ?? current.title
        let nextMemo = memo ?? current.memo
        let nextChapterID = chapterID ?? current.chapterID

        guard current.title != nextTitle || current.memo != nextMemo || current.chapterID != nextChapterID else {
            return
        }

        document.updatePlotCard(id: selectedPlotCardID, title: nextTitle, memo: nextMemo, chapterID: nextChapterID)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 選択中のプロットカードの章紐付けを更新する。`nil` は未紐付けを表す。
    func updateSelectedPlotCardChapter(_ chapterID: ChapterID?) {
        guard permitsDocumentInteraction else { return }
        guard let selectedPlotCardID, let current = selectedPlotCard else { return }
        guard current.chapterID != chapterID else { return }

        document.updatePlotCard(id: selectedPlotCardID, title: current.title, memo: current.memo, chapterID: chapterID)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// プロットカードタイトルの編集確定時に、空タイトルを正規化して即時保存へ寄せる。
    func commitPlotCardEditing() {
        guard permitsDocumentInteraction else { return }
        for card in document.plotCards {
            let normalizedTitle = NovelDocument.normalizedPlotCardTitle(card.title)
            if card.title != normalizedTitle {
                document.updatePlotCard(id: card.id, title: normalizedTitle, memo: card.memo, chapterID: card.chapterID)
                saveCoordinator.markDirty()
            }
        }
        flushSaveImmediately()
    }

    /// プロットカードを削除する。
    @discardableResult
    func deletePlotCard(id: PlotCardID, expectedSession: DocumentSessionToken? = nil) -> Bool {
        guard permitsMutation(expectedSession: expectedSession) else { return false }
        guard let originalIndex = document.plotCards.firstIndex(where: { $0.id == id }) else { return false }
        guard document.removePlotCard(id: id) != nil else { return false }

        if selectedPlotCardID == id {
            let fallbackIndex = min(originalIndex, document.plotCards.count - 1)
            selectedPlotCardID = document.plotCards.indices.contains(fallbackIndex) ?
                document.plotCards[fallbackIndex].id : nil
        }

        saveCoordinator.markDirty()
        flushSaveImmediately()
        return true
    }

    /// プロットカードを並べ替える。
    func movePlotCards(fromOffsets: IndexSet, toOffset: Int) {
        guard permitsDocumentInteraction else { return }
        document.movePlotCards(fromOffsets: fromOffsets, toOffset: toOffset)
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// プロットカードを章レーン内/レーン間で移動する。
    func movePlotCard(id: PlotCardID, toChapter chapterID: ChapterID?, before targetID: PlotCardID? = nil) {
        guard permitsDocumentInteraction else { return }
        document.movePlotCard(id: id, toChapter: chapterID, before: targetID)
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// Plot Outlineへのdropとしてカードの所属先を変更する。
    /// 存在しないカード／章、および現在と同じ所属先へのdropは拒否する。
    @discardableResult
    func movePlotCardFromOutline(id: PlotCardID, to selection: PlotOutlineSelection) -> Bool {
        guard permitsDocumentInteraction else { return false }
        if case let .chapter(chapterID) = selection, chapterID != selectedChapterID {
            guard permitsSynchronousDeviceSyncSelectionMutation else { return false }
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

        document.movePlotCard(id: id, toChapter: destinationChapterID)
        selectedPlotCardID = id
        plotOutlineSelection = selection
        if let destinationChapterID {
            setSelection(chapterID: destinationChapterID, episodeID: preferredEpisodeID(in: destinationChapterID))
        }
        saveCoordinator.markDirty()
        flushSaveImmediately()
        return true
    }

    // MARK: - 伏線

    /// 伏線を追加し、追加した伏線を選択状態にする。
    func addFlag() {
        guard permitsDocumentInteraction else { return }
        let newID = document.addFlag(title: "新しい伏線", plantedChapterID: selectedChapterID)
        selectedFlagID = newID
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// 伏線を選択する。
    func selectFlag(_ id: FlagID?) {
        guard permitsDocumentInteraction else { return }
        selectedFlagID = id
    }

    /// 選択中の伏線を更新する。
    func updateSelectedFlag(title: String? = nil, note: String? = nil) {
        guard permitsDocumentInteraction else { return }
        guard var next = selectedFlag else { return }
        let nextTitle = title ?? next.title
        let nextNote = note ?? next.note

        guard next.title != nextTitle || next.note != nextNote else { return }

        next.title = nextTitle
        next.note = nextNote
        document.updateFlag(next)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 選択中の伏線の章紐付けを更新する。
    func updateSelectedFlagChapters(plantedChapterID: ChapterID? = nil, resolvedChapterID: ChapterID? = nil) {
        guard permitsDocumentInteraction else { return }
        guard var next = selectedFlag else { return }
        let nextPlantedChapterID = plantedChapterID ?? next.plantedChapterID
        let nextResolvedChapterID = resolvedChapterID ?? next.resolvedChapterID

        guard next.plantedChapterID != nextPlantedChapterID || next.resolvedChapterID != nextResolvedChapterID else {
            return
        }

        next.plantedChapterID = nextPlantedChapterID
        next.resolvedChapterID = nextResolvedChapterID
        document.updateFlag(next)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 選択中の伏線の張った章を更新する。`nil` は未設定を表す。
    func updateSelectedFlagPlantedChapter(_ chapterID: ChapterID?) {
        guard permitsDocumentInteraction else { return }
        guard var next = selectedFlag else { return }
        guard next.plantedChapterID != chapterID else { return }

        next.plantedChapterID = chapterID
        document.updateFlag(next)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 選択中の伏線の回収章を更新する。`nil` は未設定を表す。
    func updateSelectedFlagResolvedChapter(_ chapterID: ChapterID?) {
        guard permitsDocumentInteraction else { return }
        guard var next = selectedFlag else { return }
        guard next.resolvedChapterID != chapterID else { return }

        next.resolvedChapterID = chapterID
        document.updateFlag(next)
        saveCoordinator.markDirty()
        saveCoordinator.scheduleDebouncedSave()
    }

    /// 選択中の伏線の回収状態を反転する。
    func toggleSelectedFlagResolved() {
        guard permitsDocumentInteraction else { return }
        guard var next = selectedFlag else { return }
        next.isResolved.toggle()
        next.resolvedChapterID = next.isResolved ? selectedChapterID : nil
        document.updateFlag(next)
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }

    /// 伏線タイトルの編集確定時に、空タイトルを正規化して即時保存へ寄せる。
    func commitFlagEditing() {
        guard permitsDocumentInteraction else { return }
        for flag in document.flags {
            let normalizedTitle = NovelDocument.normalizedFlagTitle(flag.title)
            if flag.title != normalizedTitle {
                var next = flag
                next.title = normalizedTitle
                document.updateFlag(next)
                saveCoordinator.markDirty()
            }
        }
        flushSaveImmediately()
    }

    /// 伏線を削除する。
    @discardableResult
    func deleteFlag(id: FlagID, expectedSession: DocumentSessionToken? = nil) -> Bool {
        guard permitsMutation(expectedSession: expectedSession) else { return false }
        guard let originalIndex = document.flags.firstIndex(where: { $0.id == id }) else { return false }
        guard document.removeFlag(id: id) != nil else { return false }

        if selectedFlagID == id {
            let fallbackIndex = min(originalIndex, document.flags.count - 1)
            selectedFlagID = document.flags.indices.contains(fallbackIndex) ? document.flags[fallbackIndex].id : nil
        }

        saveCoordinator.markDirty()
        flushSaveImmediately()
        return true
    }

    /// 伏線を並べ替える。
    func moveFlags(fromOffsets: IndexSet, toOffset: Int) {
        guard permitsDocumentInteraction else { return }
        document.moveFlags(fromOffsets: fromOffsets, toOffset: toOffset)
        saveCoordinator.markDirty()
        flushSaveImmediately()
    }
}
