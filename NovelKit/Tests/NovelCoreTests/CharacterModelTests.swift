import Foundation
import NovelCore
import Testing

@Test func characterDecodesLegacyJSONWithMissingSheetFields() throws {
    let id = CharacterID()
    let json = """
    {
      "id": {"rawValue": "\(id.rawValue.uuidString)"},
      "name": "灯",
      "kana": "あかり",
      "memo": "主人公",
      "colorHex": "#1F5A8A"
    }
    """

    let decoded = try JSONDecoder().decode(NovelCore.Character.self, from: Data(json.utf8))

    #expect(decoded.id == id)
    #expect(decoded.name == "灯")
    #expect(decoded.role == nil)
    #expect(decoded.age == nil)
    #expect(decoded.background == nil)
}

@Test func characterOmitsNilSheetFieldsWhenEncoding() throws {
    let character = NovelCore.Character(name: "灯", role: "主人公", age: nil)

    let data = try JSONEncoder().encode(character)
    let json = try #require(String(data: data, encoding: .utf8))

    #expect(json.contains("role"))
    #expect(!json.contains("age"))
    #expect(!json.contains("background"))
}
