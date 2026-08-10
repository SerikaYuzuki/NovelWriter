import Foundation
@testable import NovelSyncCloudKit
import Testing

@Suite("Apple Device Sync account gate")
struct AppleDeviceSyncAccountGateTests {
    @Test("every remote operation revalidates live account scope before work")
    func differentAccountBlocksBeforeOperation() async throws {
        let original = accountScope("account-a")
        let box = AccountScopeBox(scope: original)
        let probe = DelayedOperationProbe()
        let gate = AppleDeviceSyncAccountGate(
            expectedScope: original,
            scopeResolver: { await box.resolve() }
        )
        try await gate.performOperation {
            await probe.recordWrite()
        }
        #expect(await probe.didWrite)
        await probe.resetWrite()

        await box.setScope(accountScope("account-b"))
        await #expect(
            throws: AppleDeviceSyncServicesError.blocked(.differentCloudAccount)
        ) {
            try await gate.performOperation {
                await probe.recordWrite()
            }
        }
        let wroteAfterSwitch = await probe.didWrite
        let availability = await gate.availability()
        #expect(!wroteAfterSwitch)
        #expect(availability == .blocked(.differentCloudAccount))
    }

    @Test("an account event immediately fences and cancels an in-flight delayed write")
    func accountEventCancelsDelayedWrite() async throws {
        let original = accountScope("account-a")
        let box = AccountScopeBox(scope: original)
        let probe = DelayedOperationProbe()
        let gate = AppleDeviceSyncAccountGate(
            expectedScope: original,
            scopeResolver: { await box.resolve() }
        )
        let operation = Task {
            try await gate.performMutation {
                await probe.markStarted()
                try await Task.sleep(for: .seconds(60))
                await probe.recordWrite()
            }
        }
        await probe.waitUntilStarted()
        await box.setScope(accountScope("account-b"))

        let availability = await gate.blockForAccountChange()
        #expect(availability == .blocked(.accountUnavailable))
        await #expect(
            throws: AppleDeviceSyncServicesError.blocked(.accountUnavailable)
        ) {
            try await operation.value
        }
        let wroteAfterEvent = await probe.didWrite
        #expect(!wroteAfterEvent)
    }

    @Test("an unavailable live identity blocks before a write")
    func unavailableAccountBlocksBeforeWrite() async throws {
        let original = accountScope("account-a")
        let probe = DelayedOperationProbe()
        let gate = AppleDeviceSyncAccountGate(
            expectedScope: original,
            scopeResolver: {
                throw CloudKitSyncAdapterError.accountUnavailable(.temporarilyUnavailable)
            }
        )

        await #expect(
            throws: AppleDeviceSyncServicesError.blocked(.accountUnavailable)
        ) {
            try await gate.performMutation {
                await probe.recordWrite()
            }
        }
        let didWrite = await probe.didWrite
        #expect(!didWrite)
    }

    private func accountScope(_ userRecordName: String) -> AppleCloudAccountScope {
        AppleCloudAccountScope(
            containerIdentifier: "iCloud.dev.serikayuzuki.fuminiwa.sync",
            userRecordName: userRecordName
        )
    }
}

private actor AccountScopeBox {
    private var scope: AppleCloudAccountScope

    init(scope: AppleCloudAccountScope) {
        self.scope = scope
    }

    func resolve() -> AppleCloudAccountScope {
        scope
    }

    func setScope(_ scope: AppleCloudAccountScope) {
        self.scope = scope
    }
}

private actor DelayedOperationProbe {
    private(set) var didWrite = false
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitUntilStarted() async {
        if didStart {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func recordWrite() {
        didWrite = true
    }

    func resetWrite() {
        didWrite = false
    }
}
