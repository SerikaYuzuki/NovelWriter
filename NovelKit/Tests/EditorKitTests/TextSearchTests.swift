@testable import EditorKit
import Foundation
import Testing

@Test func forwardSearchFindsFromLocation() {
    let text = "abc abc"
    let match = TextSearch.find(query: "abc", in: text, from: 1, direction: .forward)

    #expect(match == NSRange(location: 4, length: 3))
}

@Test func forwardSearchWrapsToBeginning() {
    let text = "abc def"
    let match = TextSearch.find(query: "abc", in: text, from: 4, direction: .forward)

    #expect(match == NSRange(location: 0, length: 3))
}

@Test func backwardSearchFindsPreviousMatch() {
    let text = "abc abc"
    let match = TextSearch.find(query: "abc", in: text, from: 4, direction: .backward)

    #expect(match == NSRange(location: 0, length: 3))
}

@Test func backwardSearchWrapsToEnd() {
    let text = "abc def abc"
    let match = TextSearch.find(query: "abc", in: text, from: 0, direction: .backward)

    #expect(match == NSRange(location: 8, length: 3))
}

@Test func searchUsesUTF16Ranges() {
    let text = "😀猫😀猫"
    let match = TextSearch.find(query: "猫", in: text, from: 3, direction: .forward)

    #expect(match == NSRange(location: 5, length: 1))
}

@Test func emptyQueryDoesNotMatch() {
    let match = TextSearch.find(query: "", in: "本文", from: 0)

    #expect(match == nil)
}
