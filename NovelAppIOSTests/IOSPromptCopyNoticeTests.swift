@testable import FUMINIWAIOS
import Testing

@Suite("iOS prompt copy notice")
struct IOSPromptCopyNoticeTests {
    @Test("成功通知はAIへ送信したと表現しない")
    func successNoticePreservesProductTruth() {
        let notice = IOSPromptCopyNotice.success

        #expect(notice.title == "プロンプトをコピーしました")
        #expect(notice.message.contains("AIチャットには送信していません"))
    }

    @Test("IME中の失敗通知は確定を促す")
    func compositionFailureRequestsCommit() {
        let notice = IOSPromptCopyNotice(failure: .compositionInProgress)

        #expect(notice.title == "プロンプトをコピーできませんでした")
        #expect(notice.message.contains("日本語入力の変換を確定"))
    }
}

@Suite("iOS export filename")
struct IOSExportFilenameTests {
    @Test("path separatorをpackage名へ持ち込まない")
    func replacesPathSeparators() async {
        let filename = await IOSDocumentStore.portableExportFilename(for: "章/節:草稿")

        #expect(filename == "章_節_草稿.novelpkg")
    }

    @Test("空タイトルにも安定した名前を付ける")
    func suppliesFallbackName() async {
        let filename = await IOSDocumentStore.portableExportFilename(for: "  \n")

        #expect(filename == "新規作品.novelpkg")
    }
}
