@testable import NovelSyncCloudKit
import Testing

@Suite("CKSyncEngine boundary")
struct CloudKitChangeTrackingDriverTests {
    @Test("push changes auto-fetch while every write remains on direct CAS path")
    func pushFetchDoesNotEnableUnconditionalWrites() {
        #expect(CloudKitChangeTrackingDriver.automaticallyFetchesPushChanges)
        #expect(!CloudKitChangeTrackingDriver.sendsPendingRecordChanges)
    }
}
