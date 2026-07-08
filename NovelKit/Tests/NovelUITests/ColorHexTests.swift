import NovelUI
import Testing

@Test func colorHexParsesHashPrefixedString() {
    let components = ColorHex.components(from: "#1F5A8A")

    #expect(components == ColorHexComponents(red: 31, green: 90, blue: 138))
}

@Test func colorHexRejectsInvalidString() {
    #expect(ColorHex.components(from: "not-a-color") == nil)
    #expect(ColorHex.string(red: -1, green: 0, blue: 0) == nil)
}

@Test func colorHexFormatsUppercaseHashString() {
    #expect(ColorHex.string(red: 31, green: 90, blue: 138) == "#1F5A8A")
}
