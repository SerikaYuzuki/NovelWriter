import CryptoKit
import Foundation
import Testing

struct AuthConformanceTests {
    @Test("current Auth v1 fixtures preserve canonical bytes and digests")
    func canonicalVectorsAgree() throws {
        let files = fixtureFiles()
        try #require(!files.isEmpty, "No Auth v1 JSON fixtures were found")

        var vectorCount = 0
        for file in files {
            let data = try Data(contentsOf: file)
            let value = try JSONSerialization.jsonObject(with: data)
            vectorCount += try verify(value, source: file, location: "$")
        }
        #expect(vectorCount > 0)
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
}
