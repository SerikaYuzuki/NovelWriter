@testable import EditorKit
import Testing

struct EditorNotationRulesTests {
    @Test("ルビはなろう形式で親文字とルビをそのまま保持する")
    func rubyUsesNarouNotationWithoutEscaping() {
        #expect(EditorNotationRules.ruby(parentText: "猫｜《", rubyText: "ねこ》") == "｜猫｜《《ねこ》》")
        #expect(EditorNotationRules.ruby(parentText: "", rubyText: "ねこ") == nil)
        #expect(EditorNotationRules.ruby(parentText: "猫", rubyText: "") == nil)
    }

    @Test("傍点は選択範囲を1文字ずつのルビ点記法へ変換する")
    func boutenUsesOneRubyPointPerCharacter() {
        #expect(
            EditorNotationRules.bouten(text: "例えばこの文章") ==
                "｜例《・》｜え《・》｜ば《・》｜こ《・》｜の《・》｜文《・》｜章《・》"
        )
    }

    @Test("傍点は絵文字を1文字として変換する")
    func boutenTreatsEmojiAsOneCharacter() {
        #expect(EditorNotationRules.bouten(text: "猫😀") == "｜猫《・》｜😀《・》")
    }

    @Test("傍点は改行・半角空白・全角空白・タブをそのまま残す")
    func boutenPreservesNewlinesAndWhitespace() {
        #expect(EditorNotationRules.bouten(text: "猫 \n　\t犬") == "｜猫《・》 \n　\t｜犬《・》")
    }

    @Test("空選択または空白だけの選択では傍点を生成しない")
    func boutenReturnsNilForEmptyOrWhitespaceOnlyText() {
        #expect(EditorNotationRules.bouten(text: "") == nil)
        #expect(EditorNotationRules.bouten(text: " \n　\t") == nil)
    }
}
