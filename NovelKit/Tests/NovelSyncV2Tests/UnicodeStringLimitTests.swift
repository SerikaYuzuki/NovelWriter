import Foundation
@testable import NovelSyncV2
import Testing

@Test
func unicodeStringLimitMatchesSharedServerFixture() throws {
    struct Fixture: Decodable {
        let entityKey: String
        let maxScalars: Int
        let samples: [String]
        let scalarCounts: [Int]
    }
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0 ..< 4 {
        root.deleteLastPathComponent()
    }
    let data = try Data(contentsOf: root.appendingPathComponent("docs/sync/v2/fixtures/boundaries/unicode-string-limit.json"))
    let fixture = try JSONDecoder().decode(Fixture.self, from: data)
    for sample in fixture.samples {
        let scalars = Array(sample.unicodeScalars)
        for count in fixture.scalarCounts {
            let text = String(String.UnicodeScalarView((0 ..< count).map { scalars[$0 % scalars.count] }))
            let bytes = try JSONSerialization.data(withJSONObject: ["value": text], options: [.sortedKeys, .withoutEscapingSlashes])
            if count <= fixture.maxScalars {
                try SnapshotValidator.validateEntity(bytes, for: fixture.entityKey)
            } else {
                #expect(throws: SyncV2TypeError.self) { try SnapshotValidator.validateEntity(bytes, for: fixture.entityKey) }
            }
        }
    }
}
