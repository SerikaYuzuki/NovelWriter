import NovelUI
import Testing

/// `CharacterColorPreset`(docs/STYLE.md 2章のキャラクターカラー10色)のテスト。
struct CharacterColorPresetTests {
    @Test("プリセットはSTYLE.mdどおり10色ちょうど")
    func hasTenPresets() {
        #expect(CharacterColorPreset.hexValues.count == 10)
    }

    @Test("すべて重複のない有効な#RRGGBB形式")
    func allValuesAreDistinctValidHex() {
        let values = CharacterColorPreset.hexValues

        #expect(Set(values).count == values.count)
        for hex in values {
            #expect(ColorHex.components(from: hex) != nil)
        }
    }
}
