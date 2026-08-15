import AppKit
@testable import FUMINIWA
import NovelSync
import SwiftUI
import Testing

@MainActor
@Suite("Note sync conflict presentation")
struct NoteSyncConflictResolutionViewTests {
    @Test("短い3択は統合案と内部語を出さない")
    func shortChooserHasNoProposedPanelOrInternalWords() {
        let presentation = NoteSyncConflictPresentation(workTitle: "春の庭")

        #expect(presentation.heading == "変更の確認が必要です")
        #expect(presentation.localActionTitle == "この端末の内容を使う")
        #expect(presentation.remoteActionTitle == "iCloudの内容を使う")
        #expect(presentation.bothActionTitle == "両方を別作品として残す")
        #expect(!presentation.message.contains("統合"))
        #expect(!presentation.message.contains("revision"))
        #expect(!presentation.message.contains("branch"))
        #expect(!presentation.message.contains("merge"))
        #expect(!presentation.message.contains("journal"))
        #expect(!presentation.message.contains("lease"))
        #expect(Set([
            NoteSyncConflictChoice.keepLocal,
            .keepRemote,
            .keepBoth
        ]).count == 3)
    }

    @Test("Macの短い3択はEditorを変更せずlayoutできる")
    func shortChooserLaysOutWithoutMutatingEditor() {
        var selectedChoices: [NoteSyncConflictChoice] = []
        var postponed = false
        let host = NSHostingView(rootView: NoteSyncConflictResolutionView(
            presentation: NoteSyncConflictPresentation(workTitle: "春の庭"),
            isApplying: false,
            choose: { selectedChoices.append($0) },
            reviewLater: { postponed = true }
        ))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 360)
        host.layoutSubtreeIfNeeded()

        #expect(host.fittingSize.width >= 480)
        #expect(host.fittingSize.height >= 280)
        #expect(host.isHidden == false)
        #expect(selectedChoices.isEmpty)
        #expect(postponed == false)
    }
}
