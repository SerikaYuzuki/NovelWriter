@testable import FUMINIWAIOS
import NovelSync
import SwiftUI
import Testing
import UIKit

@MainActor
@Suite("iOS note sync conflict presentation")
struct IOSNoteSyncConflictResolutionViewTests {
    @Test("短い3択は統合案と内部語を出さない")
    func shortChooserHasNoProposedPanelOrInternalWords() {
        #expect(Set([
            NoteSyncConflictChoice.keepLocal,
            .keepRemote,
            .keepBoth
        ]).count == 3)
    }

    @Test("狭いiPhone幅の短い3択はEditorを変更せず描画できる")
    func narrowChooserRendersWithoutMutatingEditor() async {
        var selectedChoices: [NoteSyncConflictChoice] = []
        var postponed = false
        let host = UIHostingController(
            rootView: IOSNoteSyncConflictResolutionView(
                workTitle: "春の庭",
                isApplying: false,
                choose: { selectedChoices.append($0) },
                reviewLater: { postponed = true }
            )
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        host.view.frame = window.bounds
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        for _ in 0 ..< 8 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            await Task.yield()
        }

        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        #expect(image.size.width == 390)
        #expect(image.size.height == 844)
        #expect(host.view.window === window)
        #expect(selectedChoices.isEmpty)
        #expect(postponed == false)
    }
}
