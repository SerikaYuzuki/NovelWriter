import Foundation
@testable import NovelSyncV2
import Testing

@Test
func entityKeyCompiledGrammarMatchesOriginal() throws {
    let uuid = "abcdef01-2345-6789-abcd-ef0123456789"
    let workKeys = ["document", "title", "synopsis", "chapter-order", "character-order", "plot-card-order",
                    "flag-order", "world-note-order", "attachment-order"].map { "work/\($0)" }
    var valid = workKeys
    for (kind, suffixes) in [("chapter", ["title", "episode-order"]), ("episode", ["title", "body", "memo"]),
                             ("attachment", ["metadata", "bytes"])] {
        valid += suffixes.map { "\(kind)/\(uuid)/\($0)" }
    }
    valid += ["character", "plot-card", "flag", "world-note"].map { "\($0)/\(uuid)" }
    for key in valid {
        #expect(throws: Never.self) { try EntityKey(key) }
    }
    let invalid = ["", "work", "work/", "work/unknown", "work/title/extra", "episode//body", "chapter/\(uuid)/body",
                   "episode/\(uuid)/episode-order", "attachment/\(uuid)/title", "character/\(uuid)/title",
                   "episode/\(uuid.uppercased())/body", "episode/\(uuid.replacingOccurrences(of: "a", with: "g"))/body"]
    for key in invalid {
        #expect(throws: SyncV2TypeError.invalidEntityKey) { try EntityKey(key) }
    }
    for key in valid + invalid {
        for variant in [key, "x" + key, key + "/", key + "x", key + "\n", key + "\r\n", "\n" + key,
                        key.replacingOccurrences(of: "/", with: "//"), key + "\0", key + "文"] {
            #expect(EntityKey.isValid(variant) == legacyEntityKeyValid(variant))
        }
    }
}

private func legacyEntityKeyValid(_ key: String) -> Bool {
    let parts = key.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { return false }
    let uuid = #"(?:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"#
    let patterns = [
        "^work/(document|title|synopsis|chapter-order|character-order|plot-card-order|"
            + "flag-order|world-note-order|attachment-order)$",
        "^chapter/" + uuid + "/(title|episode-order)$", "^episode/" + uuid + "/(title|body|memo)$",
        "^character/" + uuid + "$", "^plot-card/" + uuid + "$", "^flag/" + uuid + "$",
        "^world-note/" + uuid + "$", "^attachment/" + uuid + "/(metadata|bytes)$"
    ]
    return patterns.contains { key.range(of: $0, options: .regularExpression) != nil }
}
