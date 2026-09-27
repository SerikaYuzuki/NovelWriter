@testable import FUMINIWA
import NovelSyncV2Application
import Testing

struct WorkbenchSyncStatusTests {
    @Test func aLocalOnlyOrUnconfirmedWorkIsNotLabeledSynced() {
        #expect(WorkbenchSyncStatus.resolve(saveState: .saved, progress: .noChanges, accountState: .unbound,
                                            isSignedIn: true, isRequesting: false).title == "端末に保存")
        #expect(WorkbenchSyncStatus.resolve(saveState: .saved, progress: .idle, accountState: .active,
                                            isSignedIn: true, isRequesting: false).title == "同期を確認")
        #expect(WorkbenchSyncStatus.resolve(saveState: .unsaved, progress: .noChanges, accountState: .active,
                                            isSignedIn: true, isRequesting: false).title == "未保存")
    }

    @Test func aVerifiedSyncHasVisibleSuccessAndFailuresHaveVisibleWarnings() {
        #expect(WorkbenchSyncStatus.resolve(saveState: .saved, progress: .noChanges, accountState: .active,
                                            isSignedIn: true, isRequesting: false).title == "同期済み")
        let failed = WorkbenchSyncStatus.resolve(saveState: .saved, progress: .receiptMismatch, accountState: .active,
                                                 isSignedIn: true, isRequesting: false)
        #expect(failed.title == "同期失敗")
        #expect(failed.isWarning)
        #expect(WorkbenchSyncStatus.resolve(saveState: .failed, progress: .noChanges, accountState: .active,
                                            isSignedIn: true, isRequesting: false).title == "保存に失敗")
    }
}
