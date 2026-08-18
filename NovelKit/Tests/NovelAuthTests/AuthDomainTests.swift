import Foundation
import NovelAuth
import NovelAuthApple
import Testing

@Suite("Auth v1 wire and session safety")
struct AuthDomainTests {
    @Test("challenge creation JCS bytes and digest match the fixture")
    func challengeJCS() {
        let command = AuthJCS.object([
            ("clientPlatform", "macos"),
            ("flow", "native"),
            ("operationId", "10000000-0000-4000-8000-000000000002"),
            ("provider", "apple")
        ])
        #expect(String(decoding: command.bytes, as: UTF8.self) == "{\"clientPlatform\":\"macos\",\"flow\":\"native\",\"operationId\":\"10000000-0000-4000-8000-000000000002\",\"provider\":\"apple\"}")
        #expect(command.bytes.count == 114)
        #expect(command.sha256.map { String(format: "%02x", $0) }.joined() == "4f44d7abc543ae94b555744edecf0a67707a178460f017e59c511d0f1799ed53")
    }

    @Test("production origin rejects path, query, userinfo, and HTTP")
    func productionConfiguration() throws {
        let invalidURLs = [
            "http://127.0.0.1:18080",
            "https://sync.example.test/v1",
            "https://user:password@sync.example.test",
            "https://sync.example.test?mode=staging"
        ]
        for value in invalidURLs {
            #expect(throws: AuthError.invalidProductionOrigin) {
                _ = try AuthClientConfiguration(origin: #require(URL(string: value)), clientVersion: "0.1.0", clientPlatform: .macos)
            }
        }
        let config = try AuthClientConfiguration(origin: #require(URL(string: "https://sync.example.test/")), clientVersion: "0.1.0", clientPlatform: .macos)
        #expect(config.clientPlatform == .macos)
    }

    @Test("URLSession diagnostics omit request details")
    func networkDiagnosticRedactsNSErrorDetails() {
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorServerCertificateUntrusted,
            userInfo: [
                NSURLErrorFailingURLStringErrorKey: "https://user:secret@example.test/private",
                NSLocalizedDescriptionKey: "certificate failed for https://user:secret@example.test/private"
            ]
        )
        #expect(AuthNetworkDiagnostic.token(for: error) == "NSURLError(code=-1202)")
        #expect(AuthNetworkDiagnostic.token(for: error)?.contains("example.test") == false)
        #expect(AuthNetworkDiagnostic.token(for: error)?.contains("secret") == false)
    }

    @Test("strict parser rejects duplicate keys, BOM, escapes, whitespace, and unsafe numbers")
    func strictCanonicalParser() {
        let invalidInputs = [
            Data(#"{"a":1,"a":2}"#.utf8),
            Data([0xEF, 0xBB, 0xBF, 0x7B, 0x7D]),
            Data(#"{"a":"\u0061"}"#.utf8),
            Data(#"{"a": 1}"#.utf8),
            Data(#"{"a":9007199254740992}"#.utf8),
            Data(#"{"a":"\uD800"}"#.utf8)
        ]
        for input in invalidInputs {
            #expect(throws: Error.self) { _ = try AuthCanonicalJSON.parse(input) }
        }
        let valid = Data(#"{"a":"é","b":0,"c":true,"d":null}"#.utf8)
        #expect(throws: Never.self) { _ = try AuthCanonicalJSON.parse(valid) }
    }

    @Test("refresh reservation is one-per-session and survives a fake restart")
    func refreshReservationRestart() async throws {
        let session = fixtureSession(generation: 1)
        let firstID = UUID(uuidString: "50000000-0000-4000-8000-000000000001")
        let secondID = UUID(uuidString: "50000000-0000-4000-8000-000000000002")
        let record = AuthVaultRecord(session: session)
        let vault = InMemoryAuthSessionVault(record: record)
        let reserved = try await vault.loadOrReserveRefreshRotation(proposed: #require(firstID), for: session)
        let second = try await vault.loadOrReserveRefreshRotation(proposed: #require(secondID), for: session)
        #expect(reserved == firstID)
        #expect(second == firstID)
        let restarted = await InMemoryAuthSessionVault(record: vault.snapshot())
        #expect(try await restarted.loadOrReserveRefreshRotation(proposed: #require(secondID), for: session) == firstID)
    }

    @Test("concurrent refresh reservation returns one rotation id")
    func concurrentRefreshReservation() async throws {
        let session = fixtureSession(generation: 1)
        let vault = InMemoryAuthSessionVault(session: session)
        let ids = try await withThrowingTaskGroup(of: UUID.self, returning: Set<UUID>.self) { group in
            for index in 0 ..< 8 {
                group.addTask {
                    let proposed = UUID(uuidString: String(format: "51000000-0000-4000-8000-%012d", index))
                    return try await vault.loadOrReserveRefreshRotation(proposed: #require(proposed), for: session)
                }
            }
            var values = Set<UUID>()
            for try await value in group {
                values.insert(value)
            }
            return values
        }
        #expect(ids.count == 1)
    }

    @Test("stale response cannot CAS over a newer generation")
    func staleRefreshCAS() async throws {
        let old = fixtureSession(generation: 1)
        let new = fixtureSession(generation: 2, refresh: "fmr1_CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC")
        let vault = InMemoryAuthSessionVault(session: new)
        let rotationID = try #require(UUID(uuidString: "52000000-0000-4000-8000-000000000001"))
        let replaced = try await vault.compareAndSwap(expectedRefreshToken: old.refreshToken, expectedGeneration: old.refreshGeneration, rotationID: rotationID, replacing: old)
        #expect(!replaced)
        #expect(try await vault.load() == new)
    }

    @Test("refresh CAS rejects an account, fence, or session binding mutation")
    func refreshCASRejectsBindingMutation() async throws {
        let current = fixtureSession(generation: 1)
        let rotationID = try #require(UUID(uuidString: "52100000-0000-4000-8000-000000000001"))
        let mutatedBindings = try [
            AuthSessionBinding(
                serverInstanceID: current.serverInstanceID,
                syncProtocolEpoch: current.syncProtocolEpoch,
                accountID: "acct_BBBBBBBBBBBBBBBB",
                accountAuthEpoch: current.accountAuthEpoch,
                accountFence: current.accountFence,
                sessionID: current.sessionID
            ),
            AuthSessionBinding(
                serverInstanceID: current.serverInstanceID,
                syncProtocolEpoch: current.syncProtocolEpoch,
                accountID: current.accountID,
                accountAuthEpoch: current.accountAuthEpoch,
                accountFence: "fence_BBBBBBBBBBBBBBBBBBBB",
                sessionID: current.sessionID
            ),
            AuthSessionBinding(
                serverInstanceID: current.serverInstanceID,
                syncProtocolEpoch: current.syncProtocolEpoch,
                accountID: current.accountID,
                accountAuthEpoch: current.accountAuthEpoch,
                accountFence: current.accountFence,
                sessionID: #require(UUID(uuidString: "40000000-0000-4000-8000-000000000099"))
            )
        ]
        let vault = InMemoryAuthSessionVault(session: current)
        _ = try await vault.loadOrReserveRefreshRotation(proposed: rotationID, for: current)
        for binding in mutatedBindings {
            let replacement = FuminiwaSession(
                binding: binding,
                tokens: AuthSessionTokens(
                    accessToken: "fma1_mutated",
                    accessTokenExpiresAt: current.accessTokenExpiresAt,
                    refreshToken: "fmr1_mutated",
                    refreshTokenExpiresAt: current.refreshTokenExpiresAt,
                    refreshGeneration: current.refreshGeneration + 1
                ),
                receipt: current.receipt
            )
            #expect(try await vault.compareAndSwap(
                expectedRefreshToken: current.refreshToken,
                expectedGeneration: current.refreshGeneration,
                rotationID: rotationID,
                replacing: replacement
            ) == false)
            #expect(try await vault.load() == current)
        }

        let coordinatorVault = InMemoryAuthSessionVault(session: current)
        let transport = BindingMutationRefreshTransport(session: FuminiwaSession(
            binding: mutatedBindings[0],
            tokens: AuthSessionTokens(
                accessToken: "fma1_mutated",
                accessTokenExpiresAt: current.accessTokenExpiresAt,
                refreshToken: "fmr1_mutated",
                refreshTokenExpiresAt: current.refreshTokenExpiresAt,
                refreshGeneration: current.refreshGeneration + 1
            ),
            receipt: current.receipt
        ))
        let coordinator = try AuthSessionCoordinator(
            transport: transport,
            vault: coordinatorVault,
            authLimits: fixtureLimits(),
            platform: .macos
        )
        do {
            _ = try await coordinator.refresh()
            Issue.record("binding mutation was accepted by the coordinator")
        } catch let error as AuthError {
            #expect(error == .staleResponse)
        }
        #expect(try await coordinatorVault.load() == current)
    }

    @Test("refresh reservation rejects a different session")
    func staleRefreshReservation() async throws {
        let current = fixtureSession(generation: 1)
        let stale = fixtureSession(generation: 1, sessionID: "40000000-0000-4000-8000-000000000002")
        let vault = InMemoryAuthSessionVault(session: current)
        do {
            _ = try await vault.loadOrReserveRefreshRotation(proposed: UUID(), for: stale)
            Issue.record("stale reservation unexpectedly succeeded")
        } catch let error as AuthError {
            #expect(error == .staleSession)
        }
    }

    @Test("save retains pending rotation for same session and clears it for a new session")
    func vaultSaveRules() throws {
        let old = fixtureSession(generation: 1)
        let rotationID = try #require(UUID(uuidString: "53000000-0000-4000-8000-000000000001"))
        var record = AuthVaultRecord(session: old, pendingRotationID: rotationID)
        record.save(old)
        #expect(record.pendingRotationID == rotationID)
        record.save(fixtureSession(generation: 1, sessionID: "40000000-0000-4000-8000-000000000002"))
        #expect(record.pendingRotationID == nil)
    }

    @Test("exchange operation journal survives restart without storing credentials")
    func exchangeOperationRestart() async throws {
        let challengeID = try #require(UUID(uuidString: "54000000-0000-4000-8000-000000000001"))
        let operationID = try #require(UUID(uuidString: "55000000-0000-4000-8000-000000000001"))
        var record = AuthVaultRecord()
        let fingerprint = "apple-exchange:\(challengeID.uuidString.lowercased())"
        _ = try record.loadOrReserveOperation(kind: .exchangeAppleNativeCredential, proposed: operationID, fingerprint: fingerprint)
        _ = try record.beginOperation(kind: .exchangeAppleNativeCredential, operationID: operationID, fingerprint: fingerprint)
        let restarted = InMemoryAuthSessionVault(record: record)
        let resumed = try await restarted.loadOrReserveOperation(kind: .exchangeAppleNativeCredential, proposed: UUID(), fingerprint: fingerprint)
        #expect(resumed.operationID == operationID)
        #expect(resumed.phase == .providerCallStarted)
        #expect(record.operations.allSatisfy { !$0.fingerprint.contains("token") })
    }

    @Test("sign-out ownership rejects a delayed Apple exchange response")
    func delayedAppleExchangeCannotCommitAfterSignOut() async throws {
        let challengeID = try #require(UUID(uuidString: "54100000-0000-4000-8000-000000000001"))
        let exchangeID = try #require(UUID(uuidString: "55100000-0000-4000-8000-000000000001"))
        let revokeID = try #require(UUID(uuidString: "56100000-0000-4000-8000-000000000001"))
        let oldSession = fixtureSession(generation: 1)
        let delayedSession = fixtureSession(
            generation: 1,
            sessionID: "40000000-0000-4000-8000-000000000002"
        )
        let fingerprint = "apple-exchange:\(challengeID.uuidString.lowercased())"
        var record = AuthVaultRecord(session: oldSession)
        _ = try record.loadOrReserveOperation(
            kind: .exchangeAppleNativeCredential,
            proposed: exchangeID,
            fingerprint: fingerprint
        )
        _ = try record.beginOperation(
            kind: .exchangeAppleNativeCredential,
            operationID: exchangeID,
            fingerprint: fingerprint
        )
        let vault = InMemoryAuthSessionVault(record: record)

        // Sign-out atomically claims the vault and removes the active session
        // while preserving only its exact revoke replay operation.
        let pending = try await vault.loadOrReserveRevokeOperation(
            proposed: revokeID,
            for: oldSession,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            receiptLifetimeSeconds: 86400
        )
        let committed = try await vault.commitOperationSession(
            kind: .exchangeAppleNativeCredential,
            operationID: exchangeID,
            fingerprint: fingerprint,
            session: delayedSession
        )

        #expect(!committed)
        #expect(try await vault.load() == nil)
        #expect(try await vault.loadPendingRevoke()?.operationID == pending.operationID)
        let afterSignOut = await vault.snapshot()
        #expect(afterSignOut.operations.allSatisfy {
            $0.operationID == pending.operationID && $0.kind == .revokeCurrentSession
        })
    }

    @Test("a fresh Apple exchange can commit while an older revoke is pending")
    func freshExchangeCoexistsWithPendingRevoke() async throws {
        let oldSession = fixtureSession(generation: 1)
        let newSession = fixtureSession(
            generation: 1,
            sessionID: "40000000-0000-4000-8000-000000000002"
        )
        let challengeID = try #require(UUID(uuidString: "54200000-0000-4000-8000-000000000001"))
        let revokeID = try #require(UUID(uuidString: "56200000-0000-4000-8000-000000000002"))
        let exchangeID = try #require(UUID(uuidString: "55200000-0000-4000-8000-000000000002"))
        let fingerprint = "apple-exchange:\(challengeID.uuidString.lowercased())"
        var record = AuthVaultRecord(session: oldSession)
        let pending = try record.loadOrReserveRevokeOperation(
            proposed: revokeID,
            for: oldSession,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            receiptLifetimeSeconds: 86400
        )
        _ = try record.loadOrReserveOperation(
            kind: .exchangeAppleNativeCredential,
            proposed: exchangeID,
            fingerprint: fingerprint
        )
        _ = try record.beginOperation(
            kind: .exchangeAppleNativeCredential,
            operationID: exchangeID,
            fingerprint: fingerprint
        )
        let vault = InMemoryAuthSessionVault(record: record)

        #expect(try await vault.commitOperationSession(
            kind: .exchangeAppleNativeCredential,
            operationID: exchangeID,
            fingerprint: fingerprint,
            session: newSession
        ))
        #expect(try await vault.load() == newSession)
        #expect(try await vault.loadPendingRevoke()?.operationID == pending.operationID)
    }
}

extension AuthDomainTests {
    @Test("exchange lost acknowledgement replays identical canonical bytes")
    func exchangeLostAckReplay() async throws {
        let challenge = fixtureChallenge(expiresAt: Date(timeIntervalSince1970: 1_800_000_000))
        let operationID = try #require(UUID(uuidString: "56000000-0000-4000-8000-000000000001"))
        let transport = ExchangeReplayTransport()
        let firstVault = InMemoryAuthSessionVault()
        let firstCoordinator = try AuthSessionCoordinator(
            transport: transport,
            vault: firstVault,
            authLimits: fixtureLimits(),
            platform: .macos,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        do {
            _ = try await firstCoordinator.completeAppleSignIn(
                challenge: challenge,
                authorizationCode: Data("code-1".utf8),
                identityToken: Data("header.payload.signature".utf8),
                operationID: operationID
            )
            Issue.record("first exchange unexpectedly succeeded")
        } catch let error as AuthError {
            #expect(error == .providerRejected)
        }

        let interruptedRecord = await firstVault.snapshot()
        let interruptedBytes = try JSONEncoder().encode(interruptedRecord)
        #expect(!String(decoding: interruptedBytes, as: UTF8.self).contains("code-1"))
        let restartedVault = await InMemoryAuthSessionVault(record: firstVault.snapshot())
        await transport.allowSuccess()
        let restartedCoordinator = try AuthSessionCoordinator(
            transport: transport,
            vault: restartedVault,
            authLimits: fixtureLimits(),
            platform: .macos,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let session = try await restartedCoordinator.completeAppleSignIn(
            challenge: challenge,
            authorizationCode: Data("code-1".utf8),
            identityToken: Data("header.payload.signature".utf8),
            operationID: operationID
        )
        #expect(session.accountID == "acct_AAAAAAAAAAAAAAAA")
        #expect(await transport.exchangeCallCount() == 2)
        let requests = await transport.exchangeRequests()
        #expect(requests.count == 2)
        #expect(requests[0] == requests[1])
        let restartedRecord = await restartedVault.snapshot()
        #expect(restartedRecord.operations.isEmpty)
        let persistedJournal = try JSONEncoder().encode(restartedRecord)
        #expect(!String(decoding: persistedJournal, as: UTF8.self).contains("code-1"))
    }

    @Test("exchange credential mismatch fails closed and explicit cleanup enables fresh sign in")
    func exchangeMismatchAndCleanup() async throws {
        let challenge = fixtureChallenge(expiresAt: Date(timeIntervalSince1970: 1_800_000_000))
        let operationID = try #require(UUID(uuidString: "57000000-0000-4000-8000-000000000001"))
        let transport = ExchangeReplayTransport()
        let firstVault = InMemoryAuthSessionVault()
        let firstCoordinator = try AuthSessionCoordinator(
            transport: transport,
            vault: firstVault,
            authLimits: fixtureLimits(),
            platform: .macos,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        do {
            _ = try await firstCoordinator.completeAppleSignIn(
                challenge: challenge,
                authorizationCode: Data("code-1".utf8),
                identityToken: Data("header.payload.signature".utf8),
                operationID: operationID
            )
        } catch {}
        let restartedVault = await InMemoryAuthSessionVault(record: firstVault.snapshot())
        let restartedCoordinator = try AuthSessionCoordinator(
            transport: transport,
            vault: restartedVault,
            authLimits: fixtureLimits(),
            platform: .macos,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        await transport.allowSuccess()
        let differentChallengeID = try #require(UUID(uuidString: "20000000-0000-4000-8000-000000000002"))
        do {
            _ = try await restartedCoordinator.completeAppleSignIn(
                challenge: fixtureChallenge(
                    expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
                    challengeID: differentChallengeID
                ),
                authorizationCode: Data("code-1".utf8),
                identityToken: Data("header.payload.signature".utf8),
                operationID: UUID()
            )
            Issue.record("challenge mismatch unexpectedly replayed")
        } catch let error as AuthError {
            #expect(error == .operationJournalConflict)
        }
        do {
            _ = try await restartedCoordinator.completeAppleSignIn(
                challenge: challenge,
                authorizationCode: Data("code-1".utf8),
                identityToken: Data("header.payload.signature".utf8),
                operationID: UUID()
            )
            Issue.record("credential mismatch unexpectedly replayed")
        } catch let error as AuthError {
            #expect(error == .operationJournalConflict)
        }
        let interruptedRecord = await restartedVault.snapshot()
        #expect(!interruptedRecord.operations.isEmpty)
        try await restartedCoordinator.discardInterruptedAppleExchange(challengeID: challenge.challengeID)
        let cleanedRecord = await restartedVault.snapshot()
        #expect(cleanedRecord.operations.isEmpty)
        _ = try await restartedCoordinator.completeAppleSignIn(
            challenge: challenge,
            authorizationCode: Data("fresh-code".utf8),
            identityToken: Data("header.payload.signature".utf8),
            operationID: UUID()
        )
        #expect(await transport.exchangeCallCount() == 2)
    }

    @Test("sign out removes local credentials even when revoke is unavailable")
    func signOutIsLocalFirst() async throws {
        let vault = InMemoryAuthSessionVault(session: fixtureSession(generation: 1))
        let coordinator = try AuthSessionCoordinator(
            transport: FailingTransport(),
            vault: vault,
            authLimits: fixtureLimits(),
            clock: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        do {
            try await coordinator.signOut()
            Issue.record("signOut unexpectedly succeeded")
        } catch let error as AuthError {
            #expect(error == .providerRejected)
        }
        #expect(try await vault.load() == nil)
        #expect(try await vault.loadPendingRevoke() != nil)
    }

    @Test("lost revoke acknowledgement keeps exact operation across restart")
    func revokeRestartReplay() async throws {
        let session = fixtureSession(generation: 1)
        let transport = RevokeTransport()
        let firstVault = InMemoryAuthSessionVault(session: session)
        let firstCoordinator = try AuthSessionCoordinator(
            transport: transport,
            vault: firstVault,
            authLimits: fixtureLimits(),
            clock: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        do {
            try await firstCoordinator.signOut()
            Issue.record("first revoke unexpectedly succeeded")
        } catch let error as AuthError {
            #expect(error == .providerRejected)
        }
        let pendingValue = try await firstVault.loadPendingRevoke()
        let pending = try #require(pendingValue)
        #expect(try await firstVault.load() == nil)
        #expect(pending.requestFingerprint == "revoke:\(session.sessionID.uuidString.lowercased())")
        #expect(pending.canonicalRequest == Data("{\"operationId\":\"\(pending.operationID.uuidString.lowercased())\",\"scope\":\"currentSession\"}".utf8))

        let restartedVault = await InMemoryAuthSessionVault(record: firstVault.snapshot())
        await transport.succeed()
        let restartedCoordinator = try AuthSessionCoordinator(
            transport: transport,
            vault: restartedVault,
            authLimits: fixtureLimits(),
            clock: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        try await restartedCoordinator.signOut()
        #expect(try await restartedVault.loadPendingRevoke() == nil)
        let operationIDs = await transport.revokeOperationIDs()
        #expect(operationIDs == [pending.operationID, pending.operationID])
        let requestBytes = await transport.revokeRequestBytes()
        let requestDigests = await transport.revokeRequestDigests()
        #expect(requestBytes == [pending.canonicalRequest, pending.canonicalRequest])
        #expect(requestDigests == [pending.requestDigest, pending.requestDigest])
    }

    @Test("pending revoke replay never signs out a newer session")
    func pendingRevokeReplayPreservesNewSession() async throws {
        let oldSession = fixtureSession(generation: 1)
        let newSession = fixtureSession(
            generation: 2,
            refresh: "fmr1_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
            sessionID: "40000000-0000-4000-8000-000000000002"
        )
        let transport = RevokeTransport()
        let vault = InMemoryAuthSessionVault(session: oldSession)
        let pending = try await vault.loadOrReserveRevokeOperation(
            proposed: #require(UUID(uuidString: "56200000-0000-4000-8000-000000000001")),
            for: oldSession,
            now: Date(timeIntervalSince1970: 1_800_000_000),
            receiptLifetimeSeconds: 86400
        )
        try await vault.save(newSession)
        await transport.succeed()

        let coordinator = try AuthSessionCoordinator(
            transport: transport,
            vault: vault,
            authLimits: fixtureLimits(),
            clock: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        try await coordinator.resumePendingRevoke()

        #expect(try await vault.load() == newSession)
        #expect(try await vault.loadPendingRevoke() == nil)
        #expect(await transport.revokeOperationIDs() == [pending.operationID])
    }

    @Test("expired pending revoke rolls forward without signing out a newer session")
    func expiredPendingRevokeReplayPreservesNewSession() async throws {
        let oldSession = fixtureSession(generation: 1)
        let newSession = fixtureSession(
            generation: 2,
            refresh: "fmr1_CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
            sessionID: "40000000-0000-4000-8000-000000000003"
        )
        let transport = RevokeTransport()
        let vault = InMemoryAuthSessionVault(session: oldSession)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let oldPending = try await vault.loadOrReserveRevokeOperation(
            proposed: #require(UUID(uuidString: "56300000-0000-4000-8000-000000000001")),
            for: oldSession,
            now: createdAt,
            receiptLifetimeSeconds: 86400
        )
        try await vault.save(newSession)
        let refreshRotationID = try #require(UUID(uuidString: "56400000-0000-4000-8000-000000000001"))
        _ = try await vault.loadOrReserveRefreshRotation(proposed: refreshRotationID, for: newSession)
        await transport.succeed()

        let coordinator = try AuthSessionCoordinator(
            transport: transport,
            vault: vault,
            authLimits: fixtureLimits(),
            clock: { oldPending.expiresAt.addingTimeInterval(1) }
        )
        try await coordinator.resumePendingRevoke()

        #expect(try await vault.load() == newSession)
        #expect(try await vault.loadPendingRevoke() == nil)
        #expect(await vault.snapshot().pendingRotationID == refreshRotationID)
        let operationIDs = await transport.revokeOperationIDs()
        #expect(operationIDs.count == 1)
        #expect(operationIDs[0] != oldPending.operationID)
    }

    @Test("expired pending revoke rolls forward across restart")
    func expiredRevokeRollForward() async throws {
        let session = fixtureSession(generation: 1)
        let transport = RevokeTransport()
        let firstVault = InMemoryAuthSessionVault(session: session)
        let firstCoordinator = try AuthSessionCoordinator(
            transport: transport,
            vault: firstVault,
            authLimits: fixtureLimits(),
            clock: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        do {
            try await firstCoordinator.signOut()
            Issue.record("first revoke unexpectedly succeeded")
        } catch {}
        let oldPending = try #require(await firstVault.loadPendingRevoke())
        let restartedVault = await InMemoryAuthSessionVault(record: firstVault.snapshot())
        await transport.succeed()
        let restartedCoordinator = try AuthSessionCoordinator(
            transport: transport,
            vault: restartedVault,
            authLimits: fixtureLimits(),
            clock: { oldPending.expiresAt.addingTimeInterval(1) }
        )
        try await restartedCoordinator.signOut()
        #expect(try await restartedVault.loadPendingRevoke() == nil)
        let operationIDs = await transport.revokeOperationIDs()
        #expect(operationIDs.count == 2)
        #expect(operationIDs[0] != operationIDs[1])
        let requests = await transport.revokeRequestBytes()
        #expect(requests.count == 2)
        #expect(requests[0] != requests[1])
    }

    @Test("server sessionRevoked is a successful sign-out outcome")
    func sessionAlreadyRevokedIsSuccess() async throws {
        let transport = RevokeTransport()
        await transport.returnSessionRevoked()
        let vault = InMemoryAuthSessionVault(session: fixtureSession(generation: 1))
        let coordinator = try AuthSessionCoordinator(
            transport: transport,
            vault: vault,
            authLimits: fixtureLimits(),
            clock: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        try await coordinator.signOut()
        #expect(try await vault.load() == nil)
        #expect(try await vault.loadPendingRevoke() == nil)
    }

    @Test("Apple callback validator rejects a mismatched state and expired challenge")
    func appleStateValidation() throws {
        let challenge = fixtureChallenge(expiresAt: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(throws: AuthError.stateMismatch) {
            try AppleAuthorizationCallbackValidator.validate(challenge: challenge, credentialState: "wrong", now: Date(timeIntervalSince1970: 1_700_000_000))
        }
        let expired = fixtureChallenge(expiresAt: Date(timeIntervalSince1970: 1_600_000_000))
        #expect(throws: AuthError.challengeExpired) {
            try AppleAuthorizationCallbackValidator.validate(challenge: expired, credentialState: expired.state, now: Date(timeIntervalSince1970: 1_700_000_000))
        }
    }

    @Test("Apple credential state handle has an isolated provider vault")
    func handleVault() async throws {
        let vault = InMemoryAppleCredentialStateHandleVault()
        try await vault.save("opaque-apple-user", providerConfigurationID: "apple-primary-fuminiwa-v1")
        #expect(try await vault.load(providerConfigurationID: "apple-primary-fuminiwa-v1") == "opaque-apple-user")
        #expect(try await vault.load(providerConfigurationID: "other") == nil)
    }
}

extension AuthDomainTests {
    private func fixtureSession(
        generation: UInt64,
        refresh: String = "fmr1_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        sessionID: String = "40000000-0000-4000-8000-000000000001"
    ) -> FuminiwaSession {
        let binding = AuthSessionBinding(
            serverInstanceID: UUID(uuidString: "00000000-0000-4000-8000-000000000001") ?? UUID(),
            syncProtocolEpoch: 2,
            accountID: "acct_AAAAAAAAAAAAAAAA",
            accountAuthEpoch: 1,
            accountFence: "fence_AAAAAAAAAAAAAAAAAAAA",
            sessionID: UUID(uuidString: sessionID) ?? UUID()
        )
        let tokens = AuthSessionTokens(
            accessToken: "fma1_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            accessTokenExpiresAt: Date(timeIntervalSince1970: 1_755_312_900),
            refreshToken: refresh,
            refreshTokenExpiresAt: Date(timeIntervalSince1970: 1_778_000_000),
            refreshGeneration: generation
        )
        let receipt = AuthReceipt(
            commandKind: "exchangeAppleNativeCredential",
            operationID: UUID(uuidString: "30000000-0000-4000-8000-000000000001") ?? UUID(),
            replayUntil: Date(timeIntervalSince1970: 1_778_000_000)
        )
        return FuminiwaSession(binding: binding, tokens: tokens, receipt: receipt)
    }

    private func fixtureLimits() throws -> AuthLimits {
        try AuthLimits(
            accessTokenLifetimeSeconds: 900,
            authReceiptLifetimeSeconds: 7_776_000,
            challengeLifetimeSeconds: 300,
            maxCanonicalCommandBytes: 65536,
            maxProviderClockSkewSeconds: 300,
            refreshTokenLifetimeSeconds: 7_776_000
        )
    }

    private func fixtureChallenge(
        expiresAt: Date,
        challengeID: UUID = UUID(uuidString: "20000000-0000-4000-8000-000000000001") ?? UUID()
    ) -> AuthChallenge {
        AuthChallenge(
            challengeID: challengeID,
            expiresAt: expiresAt,
            audience: "dev.serikayuzuki.fuminiwa",
            providerConfigurationID: "apple-primary-fuminiwa-v1",
            state: String(repeating: "A", count: 43),
            nonce: String(repeating: "B", count: 43),
            receipt: AuthReceipt(
                commandKind: "createChallenge",
                operationID: UUID(uuidString: "10000000-0000-4000-8000-000000000001") ?? UUID(),
                replayUntil: Date(timeIntervalSince1970: 1_778_000_000)
            )
        )
    }
}

private struct FailingTransport: FuminiwaAuthTransport {
    func createAppleChallenge(clientPlatform _: AuthClientPlatform, operationID _: UUID) async throws -> AuthChallenge {
        throw AuthError.providerRejected
    }

    func exchangeApple(challenge _: AuthChallenge, authorizationCode _: Data, identityToken _: Data, operationID _: UUID) async throws -> FuminiwaSession {
        throw AuthError.providerRejected
    }

    func refresh(session _: FuminiwaSession, rotationID _: UUID) async throws -> FuminiwaSession {
        throw AuthError.providerRejected
    }

    func revoke(pending _: AuthPendingRevoke) async throws {
        throw AuthError.providerRejected
    }
}

private actor ExchangeReplayTransport: FuminiwaAuthTransport {
    private var shouldFail = true
    private var requests: [Data] = []

    func allowSuccess() {
        shouldFail = false
    }

    func exchangeCallCount() -> Int {
        requests.count
    }

    func exchangeRequests() -> [Data] {
        requests
    }

    func createAppleChallenge(clientPlatform _: AuthClientPlatform, operationID _: UUID) async throws -> AuthChallenge {
        throw AuthError.providerRejected
    }

    func exchangeApple(challenge: AuthChallenge, authorizationCode: Data, identityToken: Data, operationID: UUID) async throws -> FuminiwaSession {
        let request = try AuthCanonicalRequests.exchangeApple(
            challenge: challenge,
            authorizationCode: authorizationCode,
            identityToken: identityToken,
            operationID: operationID
        )
        requests.append(request.bytes)
        if shouldFail {
            throw AuthError.providerRejected
        }
        return fixtureSession()
    }

    func refresh(session _: FuminiwaSession, rotationID _: UUID) async throws -> FuminiwaSession {
        throw AuthError.providerRejected
    }

    func revoke(pending _: AuthPendingRevoke) async throws {
        throw AuthError.providerRejected
    }

    private func fixtureSession() -> FuminiwaSession {
        let binding = AuthSessionBinding(
            serverInstanceID: UUID(uuidString: "00000000-0000-4000-8000-000000000001") ?? UUID(),
            syncProtocolEpoch: 2,
            accountID: "acct_AAAAAAAAAAAAAAAA",
            accountAuthEpoch: 1,
            accountFence: "fence_AAAAAAAAAAAAAAAAAAAA",
            sessionID: UUID(uuidString: "40000000-0000-4000-8000-000000000001") ?? UUID()
        )
        return FuminiwaSession(
            binding: binding,
            tokens: AuthSessionTokens(
                accessToken: "fma1_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                accessTokenExpiresAt: Date(timeIntervalSince1970: 1_755_312_900),
                refreshToken: "fmr1_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                refreshTokenExpiresAt: Date(timeIntervalSince1970: 1_778_000_000),
                refreshGeneration: 1
            ),
            receipt: AuthReceipt(
                commandKind: "exchangeAppleNativeCredential",
                operationID: UUID(uuidString: "30000000-0000-4000-8000-000000000001") ?? UUID(),
                replayUntil: Date(timeIntervalSince1970: 1_778_000_000)
            )
        )
    }
}

private actor BindingMutationRefreshTransport: FuminiwaAuthTransport {
    let session: FuminiwaSession

    init(session: FuminiwaSession) {
        self.session = session
    }

    func createAppleChallenge(clientPlatform _: AuthClientPlatform, operationID _: UUID) async throws -> AuthChallenge {
        throw AuthError.providerRejected
    }

    func exchangeApple(challenge _: AuthChallenge, authorizationCode _: Data, identityToken _: Data, operationID _: UUID) async throws -> FuminiwaSession {
        throw AuthError.providerRejected
    }

    func refresh(session _: FuminiwaSession, rotationID _: UUID) async throws -> FuminiwaSession {
        session
    }

    func revoke(pending _: AuthPendingRevoke) async throws {
        throw AuthError.providerRejected
    }
}

private actor RevokeTransport: FuminiwaAuthTransport {
    private var shouldFail = true
    private var shouldReturnSessionRevoked = false
    private var operationIDs: [UUID] = []
    private var requestBytes: [Data] = []
    private var requestDigests: [Data] = []

    func succeed() {
        shouldFail = false
    }

    func returnSessionRevoked() {
        shouldReturnSessionRevoked = true
        shouldFail = false
    }

    func revokeOperationIDs() -> [UUID] {
        operationIDs
    }

    func revokeRequestBytes() -> [Data] {
        requestBytes
    }

    func revokeRequestDigests() -> [Data] {
        requestDigests
    }

    func createAppleChallenge(clientPlatform _: AuthClientPlatform, operationID _: UUID) async throws -> AuthChallenge {
        throw AuthError.providerRejected
    }

    func exchangeApple(challenge _: AuthChallenge, authorizationCode _: Data, identityToken _: Data, operationID _: UUID) async throws -> FuminiwaSession {
        throw AuthError.providerRejected
    }

    func refresh(session _: FuminiwaSession, rotationID _: UUID) async throws -> FuminiwaSession {
        throw AuthError.providerRejected
    }

    func revoke(pending: AuthPendingRevoke) async throws {
        operationIDs.append(pending.operationID)
        requestBytes.append(pending.canonicalRequest)
        requestDigests.append(pending.requestDigest)
        if shouldReturnSessionRevoked {
            throw AuthError.remote(AuthRemoteError(
                code: "sessionRevoked",
                recoveryAction: .interactiveAppleSignIn,
                retryability: .afterInteractiveAuthentication,
                requestID: UUID(uuidString: "90000000-0000-4000-8000-000000000031") ?? UUID()
            ))
        }
        if shouldFail {
            throw AuthError.providerRejected
        }
    }
}
