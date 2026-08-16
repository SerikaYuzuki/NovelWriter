import CryptoKit
import Foundation
import Testing

struct R0ConformanceTests {
    @Test("reviewed v1 fixtures preserve canonical bytes and digests")
    func canonicalVectorsAgree() throws {
        let files = fixtureFiles()
        try #require(!files.isEmpty, "No reviewed v1 JSON fixtures were found")

        var vectorCount = 0
        for file in files {
            let data = try Data(contentsOf: file)
            let value = try JSONSerialization.jsonObject(with: data)
            vectorCount += try verify(value, source: file, location: "$")
        }
        #expect(vectorCount > 0)
    }

    @Test("reviewed v1 scenario fixtures retain their safety invariants")
    func scenarioContractsAgree() throws {
        let files = fixtureFiles().filter { $0.path.contains("/docs/sync/v1/fixtures/") }
        var scenarioCount = 0
        var scenarioIDs = Set<String>()
        for file in files {
            let data = try Data(contentsOf: file)
            let value = try JSONSerialization.jsonObject(with: data)
            try verifyScenarios(value, source: file, location: "$", ids: &scenarioIDs, count: &scenarioCount)
        }
        #expect(scenarioCount > 0)
    }

    @Test("lost ACK replay preserves the sealed command and head generation")
    func lostAckReplayAgrees() throws {
        let file = try #require(
            fixtureFiles().first { $0.lastPathComponent == "lost-ack-exact-retry.json" }
        )
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(root["scenarioId"] as? String == "intent-attempt-lost-ack-exact-retry")
        let commandTypes = try #require(root["commands"] as? [[String: Any]])
            .compactMap { $0["type"] as? String }
        #expect(
            commandTypes == [
                "observeRemote",
                "sealAttempt",
                "publish",
                "restartClientProcess",
                "retrySealedAttempt",
                "readBackAndAcknowledge"
            ]
        )
        let steps = try #require(root["steps"] as? [[String: Any]])
        try #require(steps.count == 6)
        let stepTwoSQLite = try #require(steps[1]["expectedSqlite"] as? [String: Any])
        let sealedAttempt = try #require(stepTwoSQLite["sealedAttempt"] as? [String: Any])
        let canonical = try #require(stepTwoSQLite["publishDigestInputCanonicalUtf8"] as? String)
        let expectedDigest = try #require(sealedAttempt["requestDigest"] as? String)
        let actualDigest = SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        #expect(actualDigest == expectedDigest)

        let stepThreeServer = try #require(steps[2]["expectedServer"] as? [String: Any])
        let stepThreeHead = try #require(stepThreeServer["head"] as? [String: Any])
        let replayGeneration = try #require(steps[4]["expectedServerHeadGeneration"] as? Int)
        let finalGeneration = try #require(steps[5]["expectedServerHeadGeneration"] as? Int)
        #expect(stepThreeHead["generation"] as? Int == 8)
        #expect(replayGeneration == 8)
        #expect(finalGeneration == 8)
        let finalSQLite = try #require(steps[5]["expectedSqlite"] as? [String: Any])
        #expect(finalSQLite["syncIntent"] is NSNull)
        #expect(finalSQLite["sealedAttempt"] is NSNull)
    }

    private func fixtureFiles() -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let directories = [
            root.appendingPathComponent("docs/sync/v1"),
            root.appendingPathComponent("docs/auth/v1")
        ]

        return directories.flatMap { directory -> [URL] in
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                return [URL]()
            }
            return enumerator.compactMap { item -> URL? in
                guard let url = item as? URL, url.pathExtension == "json" else { return nil }
                return url
            }
        }.sorted { $0.path < $1.path }
    }

    private func verify(_ value: Any, source: URL, location: String) throws -> Int {
        var count = 0
        if let object = value as? [String: Any] {
            if let canonical = object["expectedCanonicalUtf8"] as? String {
                let data = Data(canonical.utf8)
                if let expectedByteCount = object["expectedByteCount"] as? NSNumber {
                    #expect(
                        data.count == expectedByteCount.intValue,
                        "\(source.path):\(location): byte count mismatch"
                    )
                }
                let digest = SHA256.hash(data: data)
                    .map { String(format: "%02x", $0) }
                    .joined()
                if let expectedSha = object["expectedSha256"] as? String {
                    #expect(
                        digest == expectedSha,
                        "\(source.path):\(location): SHA-256 mismatch"
                    )
                }
                if let expectedHex = object["expectedCanonicalUtf8Hex"] as? String {
                    #expect(
                        data.map { String(format: "%02x", $0) }.joined() == expectedHex,
                        "\(source.path):\(location): UTF-8 hex mismatch"
                    )
                }
                count += 1
            }
            for (key, child) in object {
                count += try verify(child, source: source, location: "\(location).\(key)")
            }
        } else if let array = value as? [Any] {
            for (index, child) in array.enumerated() {
                count += try verify(child, source: source, location: "\(location)[\(index)]")
            }
        }
        return count
    }

    private func verifyScenarios(
        _ value: Any,
        source: URL,
        location: String,
        ids: inout Set<String>,
        count: inout Int
    ) throws {
        if let object = value as? [String: Any] {
            if let scenarioID = object["scenarioId"] as? String {
                #expect(!scenarioID.isEmpty, "\(source.path):\(location): empty scenarioId")
                #expect(ids.insert(scenarioID).inserted, "duplicate scenarioId: \(scenarioID)")
                #expect(object["fixtureVersion"] as? Int == 1)
                #expect(object["status"] as? String == "reviewedDesignContract")
                #expect((object["description"] as? String)?.isEmpty == false)
                if let forbidden = object["forbiddenOutcomes"] as? [Any] {
                    #expect(!forbidden.isEmpty)
                }
                if let choices = object["choices"] as? [String] {
                    #expect(choices.contains("useThisDevice"))
                    #expect(choices.contains("useOnline"))
                    #expect(choices.contains { $0.contains("keepBoth") })
                }
                if let digest = object["digestContract"] as? [String: Any] {
                    #expect(digest["publishWireContainsRequestDigest"] as? Bool == false)
                    #expect(
                        digest["publishWireFields"] as? [String] == [
                            "candidateSnapshotId",
                            "expectedHead",
                            "operationId",
                            "workId"
                        ]
                    )
                }
                if let primaryKey = object["remotePresencePrimaryKey"] as? [String] {
                    #expect(
                        primaryKey == [
                            "serverInstanceId",
                            "protocolEpoch",
                            "accountId",
                            "accountFence",
                            "objectId"
                        ]
                    )
                }
                count += 1
            }
            for (key, child) in object {
                try verifyScenarios(child, source: source, location: "\(location).\(key)", ids: &ids, count: &count)
            }
        } else if let array = value as? [Any] {
            for (index, child) in array.enumerated() {
                try verifyScenarios(child, source: source, location: "\(location)[\(index)]", ids: &ids, count: &count)
            }
        }
    }
}
