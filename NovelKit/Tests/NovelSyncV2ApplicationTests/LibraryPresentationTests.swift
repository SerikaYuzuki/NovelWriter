import Foundation
import NovelSyncV2
@testable import NovelSyncV2Application
import Testing

struct LibraryPresentationTests {
    static let progress: [SyncV2RemoteProgress] = [
        .idle, .noChanges, .pending, .syncing(operationID: UUID()), .offline,
        .authenticationRequired, .fenceChanged, .parkedDifferentAccount,
        .quarantined(.differentAccount), .quarantined(.changedFence),
        .quarantined(.invalidRemoteData), .quarantined(.unsafeLocalState),
        .retryable(.serverUnavailable), .retryable(.rateLimited), .retryable(.lostResponse),
        .retryable(.uploadExpired), .retryable(.publishLineageRejected), .needsChoice,
        .readyForSafeAdoption(inboxID: UUID()), .receiptMismatch,
        .failed(.unsupportedCommand), .failed(.invalidLocalState), .failed(.unexpected),
        .failed(.remoteDataUnavailable), .failed(.remoteWorkDeleted), .failed(.uploadTooLarge)
    ]

    @Test("Every availability, account, head and progress combination preserves shelf truth",
          arguments: [SyncV2LibraryAvailability.localOnly, .cached, .remoteOnly],
          [SyncV2LibraryAccountState.unbound, .active, .quarantined, .parkedDifferentAccount])
    func statusMatrix(availability: SyncV2LibraryAvailability, account: SyncV2LibraryAccountState) {
        for confirmed in [false, true] {
            for progress in Self.progress {
                let status = SyncV2LibraryStatus.resolve(availability: availability,
                                                         accountState: account, remoteHeadConfirmed: confirmed, progress: progress)
                let state = SyncUIState(workID: WorkID(UUID()), localDurability: .unsaved,
                                        remoteProgress: progress, lastTypedResult: .noChanges)
                #expect(status == .resolve(availability: availability, accountState: account,
                                           remoteHeadConfirmed: confirmed, state: state))
                #expect(!status.text.isEmpty)
                let allASCII = status.symbol.unicodeScalars.allSatisfy(\.isASCII)
                #expect(allASCII)
                let canSaySynced = availability != .remoteOnly && account == .active && confirmed
                    && (progress == .idle || progress == .noChanges)
                #expect((status.text == "同期済み") == canSaySynced)
                if account == .active, availability == .remoteOnly {
                    #expect(status == .init(text: "未取得", symbol: "arrow.down.circle", tone: .active))
                }
                if account == .unbound, availability != .remoteOnly {
                    #expect(status.text == "この端末のみ")
                    #expect(status.tone == .secondary)
                }
                if account == .parkedDifferentAccount {
                    #expect(status.symbol == "lock")
                    #expect(status.text == "別のアカウントのため保留中")
                }
            }
        }
    }

    @Test("Bound states use the intended symbols and tones", arguments: Self.progress)
    func boundStates(progress: SyncV2RemoteProgress) {
        let status = SyncV2LibraryStatus.resolve(availability: .cached,
                                                 accountState: .active, remoteHeadConfirmed: true, progress: progress)
        switch progress {
        case .failed, .receiptMismatch:
            #expect(status.symbol == "exclamationmark.circle")
            #expect(status.tone == .danger)
        case .needsChoice:
            #expect(status.symbol == "exclamationmark.triangle")
            #expect(status.tone == .warning)
        case .offline:
            #expect(status.tone == .offline)
        case .idle, .noChanges:
            #expect(status.tone == .success)
        case .syncing, .readyForSafeAdoption:
            #expect(status.tone == .active)
        case .pending, .retryable, .authenticationRequired, .parkedDifferentAccount:
            #expect(status.tone == .secondary)
        case .fenceChanged, .quarantined:
            #expect(status.tone == .warning)
        }
    }

    @Test("Title uses natural ordering with stable WorkID ties")
    func ordering() throws {
        let first = try WorkID(#require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")))
        let second = try WorkID(#require(UUID(uuidString: "00000000-0000-0000-0000-000000000002")))
        #expect(SyncV2LibraryPresentation.precedes(title: "作品2", workID: second, otherTitle: "作品10", otherWorkID: first))
        #expect(SyncV2LibraryPresentation.precedes(title: "同じ題名", workID: first, otherTitle: "同じ題名", otherWorkID: second))
        #expect(!SyncV2LibraryPresentation.precedes(title: "同じ題名", workID: second, otherTitle: "同じ題名", otherWorkID: first))
    }

    @Test("Failure presentation never exposes error payloads and retains actionable categories")
    func failures() {
        let secret = "private manuscript or server response"
        let error = NSError(domain: secret, code: 1, userInfo: [NSLocalizedDescriptionKey: secret])
        #expect(!remoteOnlyOpenErrorMessage(error).contains(secret))
        #expect(syncV2FailureKind(error) == .fatal(.unexpected))
        #expect(SyncV2LibraryPresentation.isOffline(.offline))
        #expect(SyncV2LibraryPresentation.isOffline(.retryable(.serverUnavailable)))
        #expect(!SyncV2LibraryPresentation.isOffline(.authenticationRequired))
        #expect(remoteOnlyOpenErrorMessage(SyncV2Failure.offline).contains("接続"))
        #expect(remoteOnlyOpenErrorMessage(SyncV2Failure.authenticationRequired).contains("サインイン"))
        #expect(remoteOnlyOpenErrorMessage(SyncV2Failure.receiptMismatch).contains("検証"))
    }
}
