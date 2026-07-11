@testable import EditorKit
import Testing

struct EditorNotationRulesTests {
    @Test("ルビはなろう形式で親文字とルビをそのまま保持する")
    func rubyUsesNarouNotationWithoutEscaping() {
        #expect(EditorNotationRules.ruby(parentText: "猫｜《", rubyText: "ねこ》") == "｜猫｜《《ねこ》》")
        #expect(EditorNotationRules.ruby(parentText: "", rubyText: "ねこ") == nil)
        #expect(EditorNotationRules.ruby(parentText: "猫", rubyText: "") == nil)
    }

    @Test("傍点は日本語・絵文字・改行をそのまま包む")
    func boutenPreservesUnicodeAndNewlines() {
        #expect(EditorNotationRules.bouten(text: "猫😀\n犬") == "《《猫😀\n犬》》")
        #expect(EditorNotationRules.bouten(text: "") == nil)
    }
}
