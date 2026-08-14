import CloudKit
import Foundation
@testable import NovelSyncCloudKit
import Testing

@Suite("CloudKit error mapping")
struct CloudKitErrorMappingTests {
    @Test("CAS, missing record, and account failures retain typed meanings")
    func typedMappings() {
        #expect(CloudKitErrorMapper.map(CKError(.serverRecordChanged)) == .serverRecordChanged)
        #expect(CloudKitErrorMapper.map(CKError(.unknownItem)) == .recordNotFound)
        #expect(CloudKitErrorMapper.map(CKError(.zoneNotFound)) == .zoneUnavailable)
        #expect(CloudKitErrorMapper.map(CKError(.userDeletedZone)) == .zoneReset)
        #expect(
            CloudKitErrorMapper.map(CKError(.notAuthenticated))
                == .accountUnavailable(.noAccount)
        )
        #expect(CloudKitErrorMapper.containsServerRecordChanged(CKError(.serverRecordChanged)))
        #expect(CloudKitErrorMapper.isUnknownItem(CKError(.unknownItem)))
        #expect(!CloudKitErrorMapper.isUnknownItem(CKError(.zoneNotFound)))
        #expect(!CloudKitErrorMapper.isUnknownItem(CKError(.userDeletedZone)))
    }

    @Test("partial failure preserves all material categories")
    func partialFailureMapping() {
        let partial = CKError(
            .partialFailure,
            userInfo: [
                CKPartialErrorsByItemIDKey: [
                    "control": CKError(.serverRecordChanged),
                    "revision": CKError(.unknownItem),
                    "account": CKError(.notAuthenticated),
                    "zone": CKError(.userDeletedZone)
                ]
            ]
        )
        #expect(
            CloudKitErrorMapper.map(partial) == .partialFailure([
                .serverRecordChanged,
                .unknownItem,
                .accountUnavailable,
                .zoneReset
            ])
        )
        #expect(CloudKitErrorMapper.containsServerRecordChanged(partial))
        #expect(CloudKitErrorMapper.isZoneReset(partial))
        #expect(!CloudKitErrorMapper.isUnknownItem(partial))
    }

    @Test("transient failures retain retry metadata")
    func transientFailureMapping() {
        let error = CKError(
            .requestRateLimited,
            userInfo: [CKErrorRetryAfterKey: NSNumber(value: 2.5)]
        )
        #expect(
            CloudKitErrorMapper.map(error)
                == .temporarilyUnavailable(retryAfterSeconds: 2.5)
        )
        #expect(CloudKitErrorMapper.isTransient(error))
        #expect(
            CloudKitErrorMapper.isTransient(
                CloudKitSyncAdapterError.accountUnavailable(.temporarilyUnavailable)
            )
        )
        #expect(
            CloudKitErrorMapper.isTransient(
                CloudKitSyncAdapterError.partialFailure([.temporarilyUnavailable])
            )
        )
        #expect(
            !CloudKitErrorMapper.isTransient(
                CloudKitSyncAdapterError.partialFailure([
                    .temporarilyUnavailable,
                    .permissionFailure
                ])
            )
        )
    }

    @Test("diagnostic token keeps CKError codes and drops paths")
    func diagnosticTokenIsContentFree() {
        let cloud = CKError(
            .unknownItem,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "/Users/secret/SyncWorkingCopies-v2/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE.novelpkg"
            ]
        )
        let token = CloudKitSyncDiagnostic.token(for: cloud)
        #expect(token.contains("CKError.unknownItem"))
        #expect(token.contains("recordNotFound"))
        #expect(!token.contains("/Users"))
        #expect(!token.contains("novelpkg"))
        #expect(!token.contains("AAAAAAAA"))

        let mapped = CloudKitSyncDiagnostic.token(
            for: CloudKitSyncAdapterError.invalidArguments
        )
        #expect(mapped == "CloudKitSyncAdapterError.invalidArguments")
    }

    @Test("query schema errors are not treated as offline")
    func diagnosticOfflineClassification() {
        #expect(CloudKitSyncDiagnostic.looksTemporarilyOffline(CKError(.networkUnavailable)))
        #expect(CloudKitSyncDiagnostic.looksTemporarilyOffline(CKError(.notAuthenticated)))
        #expect(CloudKitSyncDiagnostic.looksTemporarilyOffline(CKError(.zoneNotFound)))
        #expect(!CloudKitSyncDiagnostic.looksTemporarilyOffline(CKError(.invalidArguments)))
        #expect(
            !CloudKitSyncDiagnostic.looksTemporarilyOffline(
                CloudKitSyncAdapterError.invalidArguments
            )
        )
        #expect(
            CloudKitErrorMapper.map(CloudKitSyncAdapterError.invalidArguments)
                == .invalidArguments
        )
        #expect(
            CloudKitSyncDiagnostic.looksTemporarilyOffline(
                CloudKitSyncAdapterError.temporarilyUnavailable(retryAfterSeconds: nil)
            )
        )
        #expect(
            CloudKitSyncDiagnostic.looksTemporarilyOffline(
                CloudKitSyncAdapterError.accountUnavailable(.noAccount)
            )
        )
    }
}
