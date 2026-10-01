import NovelSyncV2Application
import Testing

@Suite("D-106 history presentation")
struct BackfillPresentationTests {
    @Test(arguments: SyncV2HistoryFetchState.allCases)
    func stateMapping(state: SyncV2HistoryFetchState) {
        let labels: [SyncV2HistoryFetchState: String] = [
            .complete: "履歴を取得しました", .running: "古い履歴を取得中…",
            .paused: "オンラインで取得", .offline: "オンラインで取得", .constrained: "オンラインで取得",
            .interrupted: "古い履歴を取得できませんでした・通信が途切れました",
            .validationFailed: "サーバーの履歴を確認できませんでした", .suspended: "アカウントの状態を確認してください"
        ]
        #expect(state.label == labels[state])
        switch state {
        case .complete, .running, .suspended: #expect(state.actionLabel == nil)
        case .paused, .offline, .constrained: #expect(state.actionLabel == "オンラインで取得")
        case .interrupted, .validationFailed: #expect(state.actionLabel == "再試行")
        }
        #expect((state.details != nil) == (state == .validationFailed))
    }

    @Test func restoreAndConflictMessagesUseSharedMapping() {
        #expect(SyncV2HistoryFetchState.restoreNotice == "この版はまだ端末にありません。取得後に復元できます。")
        #expect(SyncV2RemoteProgress.retryable(.historyIncomplete).japaneseLabel ==
            "サーバーの変更を確認するため古い履歴を取得しています。原稿は端末に保存済みです。")
        let status = SyncV2LibraryStatus.resolve(availability: .cached, accountState: .active,
                                                 remoteHeadConfirmed: true, progress: .retryable(.historyIncomplete))
        #expect(status.text == SyncV2HistoryFetchState.conflictWaiting)
        #expect(SyncV2HistoryFetchState.validationFailed.details ==
            "取得した履歴の整合性を確認できないため停止しました。端末の原稿と未送信の変更は保持しています。自動では再試行しません。")
    }
}
