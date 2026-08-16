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

    @Test("conflict resolution preserves a newer edit for every choice")
    func conflictResolutionReplayAgrees() throws {
        let file = try #require(
            fixtureFiles().first { $0.lastPathComponent == "concurrent-edit-during-resolution.json" }
        )
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(root["scenarioId"] as? String == "conflict-concurrent-edit-during-resolution")
        #expect(root["choices"] as? [String] == ["useThisDevice", "useOnline", "keepBoth"])
        #expect(
            root["commandSequence"] as? [String] == [
                "flushAndSealPendingResolutionAtGeneration52",
                "sendAtLeastOneByte",
                "autosaveEditAsGeneration53",
                "serverCommitResolutionAndLoseResponse",
                "restartAndReplayExactCommand",
                "readBackAndConditionallyAcknowledge"
            ]
        )
        let initial = try #require(root["sharedInitialState"] as? [String: Any])
        #expect(initial["sourceLocalGeneration"] as? Int == 52)
        #expect(initial["newerLocalGeneration"] as? Int == 53)
        let expected = try #require(root["expectedForEveryChoice"] as? [String: Any])
        #expect(expected["resolvedRemoteHeadGeneration"] as? Int == 10)
        #expect(expected["acknowledgedThroughLocalGeneration"] as? Int == 52)
        #expect(expected["activeEditorInjectionCount"] as? Int == 0)
        #expect(expected["exactCommandReplayCountAfterLostAck"] as? Int == 1)
        let local = try #require(expected["localCurrentAfterAcknowledge"] as? [String: Any])
        let intent = try #require(expected["syncIntentAfterAcknowledge"] as? [String: Any])
        #expect(local["localGeneration"] as? Int == 53)
        #expect(intent["localGeneration"] as? Int == 53)
        let keepBoth = try #require(root["keepBothAdditionalExpectation"] as? [String: Any])
        #expect(keepBoth["cloneRootPublishedExactlyOnce"] as? Bool == true)
        #expect(keepBoth["partialOriginalOrCloneCommitAllowed"] as? Bool == false)
    }

    @Test("durable local Intent blocks remote fast-forward")
    func remoteAdvanceReplayAgrees() throws {
        let file = try #require(
            fixtureFiles().first { $0.lastPathComponent == "saved-local-pending-remote-advance.json" }
        )
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(root["scenarioId"] as? String == "saved-local-pending-remote-advance")
        let initial = try #require(root["initialState"] as? [String: Any])
        let expected = try #require(root["expected"] as? [String: Any])
        let command = try #require(root["command"] as? [String: Any])
        #expect(command["type"] as? String == "stageRemoteAndEvaluateFastForward")
        #expect(initial["editorHasUnsavedChanges"] as? Bool == false)
        #expect(initial["pendingSyncIntent"] is [String: Any])
        #expect(expected["remoteStoredInInbox"] as? Bool == true)
        #expect(expected["fastForwardApplied"] as? Bool == false)
        #expect(expected["currentLocalSnapshotId"] as? String == initial["currentLocalSnapshotId"] as? String)
        #expect(expected["pendingSyncIntentPreserved"] as? Bool == true)
        #expect(expected["remoteCallbackInjectedIntoActiveEditor"] as? Bool == false)
        #expect(expected["nextAction"] as? String == "reconcile")
    }

    @Test("refresh rotation replays exactly and rejects token reuse")
    func refreshRotationReplayAgrees() throws {
        let file = try #require(
            fixtureFiles().first { $0.lastPathComponent == "refresh-rotation.json" }
        )
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(root["name"] as? String == "one-time-refresh-rotation-exact-replay-and-reuse-revocation")
        let steps = try #require(root["steps"] as? [[String: Any]])
        try #require(steps.count >= 6)
        let first = try #require(steps[0]["expect"] as? [String: Any])
        #expect(steps[0]["path"] as? String == "/v1/auth/tokens:refresh")
        #expect(first["status"] as? Int == 200)
        let replay = try #require(steps[1]["expect"] as? [String: Any])
        #expect(replay["sameCanonicalResponseAsStep"] as? String == "rotate-first-use")
        let reuse = try #require(steps[2]["expect"] as? [String: Any])
        let reuseBody = try #require(reuse["body"] as? [String: Any])
        #expect(reuse["status"] as? Int == 401)
        #expect(reuseBody["code"] as? String == "refreshTokenReused")
        #expect(reuseBody["recoveryAction"] as? String == "interactiveAppleSignIn")
        let firstState = try #require(steps[0]["expectState"] as? [String: Any])
        let reuseState = try #require(steps[2]["expectState"] as? [String: Any])
        #expect(firstState["accountAuthEpoch"] as? Int == reuseState["accountAuthEpoch"] as? Int)
        #expect(firstState["appleProviderCalls"] as? Int == 0)
        #expect(reuseState["appleProviderCalls"] as? Int == 0)
        let delayed = try #require(steps[steps.count - 1]["expect"] as? [String: Any])
        #expect(delayed["keychainCompareAndSwap"] as? String == "rejectedPredecessorMismatch")
    }

    @Test("Apple exchange keeps one identity and rejects invalid claims")
    func appleExchangeReplayAgrees() throws {
        let file = try #require(
            fixtureFiles().first { $0.lastPathComponent == "apple-native-exchange.json" }
        )
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(root["name"] as? String == "apple-native-validation-mapping-and-exact-replay")
        let steps = try #require(root["steps"] as? [[String: Any]])
        let byID = Dictionary(uniqueKeysWithValues: steps.compactMap { step -> (String, [String: Any])? in
            guard let id = step["id"] as? String else { return nil }
            return (id, step)
        })
        for (id, status) in [
            ("read-public-capabilities", 200),
            ("create-success-challenge", 201),
            ("exchange-success", 200),
            ("reauth-exchange-same-identity", 200)
        ] {
            let expect = try #require(byID[id]?["expect"] as? [String: Any])
            #expect(expect["status"] as? Int == status)
        }
        let challengeExpect = try #require(byID["create-success-challenge"]?["expect"] as? [String: Any])
        let challengeBody = try #require(challengeExpect["body"] as? [String: Any])
        #expect(challengeBody["provider"] as? String == "apple")
        #expect(challengeBody["receipt"] is [String: Any])
        let challengeReplay = try #require(byID["create-success-challenge-lost-ack-replay"]?["expect"] as? [String: Any])
        #expect(challengeReplay["sameCanonicalResponseAsStep"] as? String == "create-success-challenge")
        let exchangeReplay = try #require(byID["exchange-success-lost-ack-replay"]?["expect"] as? [String: Any])
        #expect(exchangeReplay["sameCanonicalResponseAsStep"] as? String == "exchange-success")
        let success = try #require(byID["exchange-success"]?["expect"] as? [String: Any])
        let successBody = try #require(success["body"] as? [String: Any])
        let successBinding = try #require(successBody["binding"] as? [String: Any])
        let reauth = try #require(byID["reauth-exchange-same-identity"]?["expect"] as? [String: Any])
        let reauthBody = try #require(reauth["body"] as? [String: Any])
        let reauthBinding = try #require(reauthBody["binding"] as? [String: Any])
        #expect(successBinding["accountId"] as? String == reauthBinding["accountId"] as? String)
        #expect(successBinding["accountFence"] as? String == reauthBinding["accountFence"] as? String)
        let reauthState = try #require(byID["reauth-exchange-same-identity"]?["expectState"] as? [String: Any])
        #expect(reauthState["externalIdentityMappings"] as? Int == 1)
        for id in ["exchange-wrong-state", "exchange-wrong-issuer", "exchange-wrong-audience", "exchange-wrong-nonce"] {
            let expect = try #require(byID[id]?["expect"] as? [String: Any])
            let state = try #require(byID[id]?["expectState"] as? [String: Any])
            #expect(expect["status"] as? Int == 422)
            #expect(state["accountMutation"] as? Bool == false)
        }
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
            for (utf8Key, rawCanonical) in object {
                guard utf8Key.hasPrefix("expectedCanonical"), utf8Key.hasSuffix("Utf8"),
                      let canonical = rawCanonical as? String else { continue }
                let data = Data(canonical.utf8)
                let prefix = String(utf8Key.dropLast(4))
                if let expectedByteCount = object["\(prefix)ByteCount"] as? NSNumber {
                    #expect(
                        data.count == expectedByteCount.intValue,
                        "\(source.path):\(location): byte count mismatch"
                    )
                }
                let digest = SHA256.hash(data: data)
                    .map { String(format: "%02x", $0) }
                    .joined()
                if let expectedSha = object["\(prefix)Sha256"] as? String {
                    #expect(
                        digest == expectedSha,
                        "\(source.path):\(location): SHA-256 mismatch"
                    )
                }
                if utf8Key == "expectedCanonicalUtf8", let expectedHex = object["expectedCanonicalUtf8Hex"] as? String {
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
