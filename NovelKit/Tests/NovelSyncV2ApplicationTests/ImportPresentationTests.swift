import NovelSyncV2
import NovelSyncV2Application
import Testing

struct ImportPresentationTests {
    @Test("all import phase strings are shared by both platforms")
    func phaseStrings() {
        #expect(ImportPhase(receivedBytes: 8_200_000, totalBytes: 19_000_000).japaneseLabel == "サーバーから受信中 8.2 / 19 MB")
        #expect(ImportPhase(receivedBytes: 8_200_000).japaneseLabel == "サーバーから受信中 8.2 MB")
        #expect(ImportPhase(stage: .checking).japaneseLabel == "内容を確認中…")
        #expect(ImportPhase(stage: .saving).japaneseLabel == "この端末に保存中…")
        #expect(ImportPhase(stage: .opening).japaneseLabel == "開いています…")
        #expect(ImportPhase(receivedBytes: 40, totalBytes: 100).accessibilityValue == "取り込み中、40パーセント")
        #expect(ImportPhase(stage: .checking).accessibilityValue == "取り込み中、内容を確認中…")
        #expect(SyncV2LibraryPresentation.importFailure(.retryable(.lostResponse)) == "取り込めませんでした・通信が途切れました")
    }
}
