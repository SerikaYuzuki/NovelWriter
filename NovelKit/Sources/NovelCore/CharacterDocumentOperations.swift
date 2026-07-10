import Foundation

public extension NovelDocument {
    /// 空白だけの登場人物名を、保存・表示に耐える名前へ正規化する。
    static func normalizedCharacterName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "名無し" : trimmed
    }

    /// 末尾に登場人物を追加する。
    @discardableResult
    mutating func addCharacter(
        name: String,
        kana: String = "",
        memo: String = "",
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
    ) -> CharacterID {
        let character = Character(
            name: Self.normalizedCharacterName(name),
            kana: kana,
            memo: memo,
            colorHex: colorHex,
            role: role,
            age: age,
            gender: gender,
            firstPerson: firstPerson,
            secondPerson: secondPerson,
            speechStyle: speechStyle,
            appearance: appearance,
            personality: personality,
            background: background
        )
        characters.append(character)
        return character.id
    }

    /// 指定した登場人物を削除する。
    @discardableResult
    mutating func removeCharacter(id: CharacterID) -> Character? {
        guard let index = characters.firstIndex(where: { $0.id == id }) else { return nil }
        return characters.remove(at: index)
    }

    /// 登場人物を並べ替える。
    mutating func moveCharacters(fromOffsets: IndexSet, toOffset: Int) {
        let itemsToMove = fromOffsets.map { characters[$0] }
        for index in fromOffsets.sorted(by: >) {
            characters.remove(at: index)
        }
        let removedBeforeDestination = fromOffsets.count(where: { $0 < toOffset })
        let adjustedDestination = toOffset - removedBeforeDestination
        characters.insert(contentsOf: itemsToMove, at: adjustedDestination)
    }

    /// 指定した登場人物を更新する。
    mutating func updateCharacter(
        id: CharacterID,
        name: String,
        kana: String,
        memo: String,
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
        guard let index = characters.firstIndex(where: { $0.id == id }) else { return }
        characters[index].name = name
        characters[index].kana = kana
        characters[index].memo = memo
        characters[index].colorHex = colorHex
        characters[index].role = role
        characters[index].age = age
        characters[index].gender = gender
        characters[index].firstPerson = firstPerson
        characters[index].secondPerson = secondPerson
        characters[index].speechStyle = speechStyle
        characters[index].appearance = appearance
        characters[index].personality = personality
        characters[index].background = background
    }
}
