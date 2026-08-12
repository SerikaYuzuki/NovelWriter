import Foundation
import NovelSync
import Testing

@Suite("Portable three-way text merge")
struct PortableThreeWayTextMergerTests {
    @Test("versioned cross-platform fixture produces canonical merge results")
    func versionedFixture() throws {
        let url = try #require(
            Bundle.module.url(forResource: "portable-text-merge-v1", withExtension: "json")
        )
        let fixtureData = try Data(contentsOf: url)
        let fixture = try JSONDecoder().decode(
            PortableMergeFixture.self,
            from: fixtureData
        )
        #expect(fixture.protocolVersion == SyncWireProtocol.currentVersion)

        for fixtureCase in fixture.cases {
            if let limit = fixtureCase.limit {
                #expect(limit.maximumInputUTF8Bytes == PortableThreeWayTextMerger.maximumInputUTF8Bytes)
                #expect(limit.maximumInputScalarCount == PortableThreeWayTextMerger.maximumInputScalarCount)
                #expect(limit.maximumEditDistance == PortableThreeWayTextMerger.maximumEditDistance)
                #expect(limit.maximumDiffWork == PortableThreeWayTextMerger.maximumDiffWork)
                #expect(fixtureCase.expected.reason == .inputLimitExceeded)
                continue
            }
            let result = try PortableThreeWayTextMerger.merge(
                base: #require(fixtureCase.base),
                local: #require(fixtureCase.local),
                remote: #require(fixtureCase.remote)
            )
            #expect(result == fixtureCase.expected.result)
            if let proposedContent = fixtureCase.expected.proposedContent,
               let reason = fixtureCase.expected.reason {
                #expect(
                    try PortableThreeWayTextMerger.analyze(
                        base: #require(fixtureCase.base),
                        local: #require(fixtureCase.local),
                        remote: #require(fixtureCase.remote)
                    ) == .conflict(
                        PortableTextMergeConflict(
                            reason: reason,
                            proposedContent: proposedContent
                        )
                    )
                )
            }
        }

        let fixtureText = try #require(String(data: fixtureData, encoding: .utf8))
        let unsupported = fixtureText
            .replacingOccurrences(of: "\"protocolVersion\": 1", with: "\"protocolVersion\": 2")
        #expect(throws: SyncWireError.self) {
            _ = try JSONDecoder().decode(
                PortableMergeFixture.self,
                from: Data(unsupported.utf8)
            )
        }
    }

    @Test("Japanese non-overlapping edits merge in base order")
    func japaneseNonOverlapping() {
        let result = PortableThreeWayTextMerger.merge(
            base: "吾輩は猫である。名前はまだない。",
            local: "吾輩は黒猫である。名前はまだない。",
            remote: "吾輩は猫である。名前はまだ無い。"
        )
        #expect(result == .merged("吾輩は黒猫である。名前はまだ無い。"))
    }

    @Test("emoji and combining scalar edits remain byte-for-byte deterministic")
    func emojiAndCombiningScalars() {
        let base = "A😀B e\u{301} C"
        let local = "A🐈B e\u{301} C"
        let remote = "A😀B e\u{301} Ｃ"
        #expect(
            PortableThreeWayTextMerger.merge(base: base, local: local, remote: remote)
                == .merged("A🐈B e\u{301} Ｃ")
        )
    }

    @Test("full-width whitespace insertions at different points merge")
    func fullWidthWhitespace() {
        #expect(
            PortableThreeWayTextMerger.merge(
                base: "甲乙丙",
                local: "甲　乙丙",
                remote: "甲乙　丙"
            ) == .merged("甲　乙　丙")
        )
    }

    @Test("multiple disjoint local hunks and a separate remote hunk merge automatically")
    func multipleDisjointHunks() {
        #expect(
            PortableThreeWayTextMerger.merge(
                base: "甲\n乙\n丙\n丁\n戊\n",
                local: "甲L\n乙\n丙\n丁\n戊L\n",
                remote: "甲\n乙\n丙R\n丁\n戊\n"
            ) == .merged("甲L\n乙\n丙R\n丁\n戊L\n")
        )
    }

    @Test("conflict draft applies every non-overlapping hunk and keeps local at the overlap")
    func partialConflictDraft() {
        let analysis = PortableThreeWayTextMerger.analyze(
            base: "甲\n乙\n丙\n丁\n戊\n",
            local: "甲L\n乙\n狼LOCAL\n丁\n戊L\n",
            remote: "甲\n乙R\n猫REMOTE\n丁R\n戊\n"
        )
        #expect(
            analysis == .conflict(
                PortableTextMergeConflict(
                    reason: .overlappingChanges,
                    proposedContent: "甲L\n乙R\n狼LOCAL\n丁R\n戊L\n"
                )
            )
        )
    }

    @Test("multi-hunk scalar coordinates preserve emoji, combining marks, and full-width space")
    func unicodeMultiHunk() {
        #expect(
            PortableThreeWayTextMerger.merge(
                base: "序😀\nかなe\u{301}\n　終\n",
                local: "序🐈\nかなe\u{301}\n　終！\n",
                remote: "序😀\n仮名e\u{301}\n　終\n"
            ) == .merged("序🐈\n仮名e\u{301}\n　終！\n")
        )
    }

    @Test("same insertion point and overlapping changes stay conflicted")
    func ambiguousEditsConflict() {
        #expect(
            PortableThreeWayTextMerger.merge(base: "甲乙", local: "甲A乙", remote: "甲B乙")
                == .conflict(.sameInsertionPoint)
        )
        #expect(
            PortableThreeWayTextMerger.merge(base: "abcdef", local: "abXXef", remote: "abcYYf")
                == .conflict(.overlappingChanges)
        )
    }

    @Test("insertions at replacement or deletion boundaries are disjoint and side-order independent")
    func insertionBoundariesAreDisjoint() {
        let cases = [
            MergeBoundaryCase(local: "Xab", remote: "Ab", expected: "XAb"),
            MergeBoundaryCase(local: "Ab", remote: "Xab", expected: "XAb"),
            MergeBoundaryCase(local: "abX", remote: "aB", expected: "aBX"),
            MergeBoundaryCase(local: "aB", remote: "abX", expected: "aBX"),
            MergeBoundaryCase(local: "Xab", remote: "b", expected: "Xb"),
            MergeBoundaryCase(local: "b", remote: "Xab", expected: "Xb"),
            MergeBoundaryCase(local: "abX", remote: "a", expected: "aX"),
            MergeBoundaryCase(local: "a", remote: "abX", expected: "aX")
        ]
        for mergeCase in cases {
            #expect(
                PortableThreeWayTextMerger.merge(
                    base: "ab",
                    local: mergeCase.local,
                    remote: mergeCase.remote
                ) == .merged(mergeCase.expected)
            )
        }
    }

    @Test("inside insertions still conflict and equal same-point insertions collapse once")
    func insertionInteriorAndSamePoint() {
        #expect(
            PortableThreeWayTextMerger.merge(
                base: "abc",
                local: "aXbc",
                remote: "c"
            ) == .conflict(.overlappingChanges)
        )
        #expect(
            PortableThreeWayTextMerger.merge(base: "ab", local: "aXb", remote: "aXb")
                == .merged("aXb")
        )
        #expect(
            PortableThreeWayTextMerger.merge(base: "ab", local: "aXb", remote: "aYb")
                == .conflict(.sameInsertionPoint)
        )
    }

    @Test("input above the bounded merge budget stays conflicted")
    func inputLimit() {
        let oversized = String(repeating: "a", count: PortableThreeWayTextMerger.maximumInputUTF8Bytes + 1)
        #expect(
            PortableThreeWayTextMerger.merge(base: oversized, local: oversized + "x", remote: oversized)
                == .conflict(.inputLimitExceeded)
        )
    }
}

private struct MergeBoundaryCase {
    let local: String
    let remote: String
    let expected: String
}

private struct PortableMergeFixture: Decodable {
    let protocolVersion: Int
    let cases: [PortableMergeFixtureCase]

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case cases
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        guard protocolVersion == SyncWireProtocol.currentVersion else {
            throw SyncWireError.unsupportedProtocolVersion(protocolVersion)
        }
        cases = try container.decode([PortableMergeFixtureCase].self, forKey: .cases)
    }
}

private struct PortableMergeFixtureCase: Decodable {
    let name: String
    let base: String?
    let local: String?
    let remote: String?
    let limit: PortableMergeLimit?
    let expected: PortableMergeExpectation
}

private struct PortableMergeLimit: Decodable {
    let maximumInputUTF8Bytes: Int
    let maximumInputScalarCount: Int
    let maximumEditDistance: Int
    let maximumDiffWork: Int
}

private struct PortableMergeExpectation: Decodable {
    enum Kind: String, Decodable {
        case merged
        case conflict
    }

    let kind: Kind
    let content: String?
    let reason: PortableTextMergeConflictReason?
    let proposedContent: String?

    var result: PortableTextMergeResult {
        switch kind {
        case .merged:
            .merged(content ?? "")
        case .conflict:
            .conflict(reason ?? .ambiguousChanges)
        }
    }
}
