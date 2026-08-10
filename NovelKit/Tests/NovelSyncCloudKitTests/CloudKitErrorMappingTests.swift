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
    }
}
