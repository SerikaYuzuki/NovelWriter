#if canImport(UIKit) && !canImport(AppKit)
@testable import EditorKit
import Foundation
import Testing
import UIKit

extension IOSTextAdapterIntegrationTests {
    /// Delegate/text extraction costs only. UIKit replacement is measured separately;
    /// no keyboard prediction, real IME, app-model callback or physical-device thermal claim.
    @Test func typingEnergy100KDelegateMeasurement() {
        let harness = makeHarness(initialText: String(repeating: "文", count: 100_000))
        let view = harness.textView, coordinator = harness.coordinator
        var should: [Double] = [], change: [Double] = [], replace: [Double] = []
        for index in 0 ..< 25 {
            let range = NSRange(location: 50000, length: 0)
            let start = ContinuousClock.now
            let allowed = coordinator.textView(view, shouldChangeTextIn: range, replacementText: "字")
            let afterShould = ContinuousClock.now
            #expect(allowed)
            view.textStorage.replaceCharacters(in: range, with: "字")
            let afterReplace = ContinuousClock.now
            coordinator.textViewDidChange(view)
            let afterChange = ContinuousClock.now
            if index >= 5 {
                should.append(energyMilliseconds(start.duration(to: afterShould)))
                replace.append(energyMilliseconds(afterShould.duration(to: afterReplace)))
                change.append(energyMilliseconds(afterReplace.duration(to: afterChange)))
            }
        }
        #expect(harness.changes.received.last?.count == 100_025)
        let delegates = zip(should, change).map(+)
        print("TYPING editor 100000 chars 20 samples median_ms "
            + "shouldChange=\(should.sorted()[10]) didChange=\(change.sorted()[10]) "
            + "delegateTotal=\(delegates.sorted()[10]) replacement=\(replace.sorted()[10]) "
            + "maxDelegate=\(delegates.max()!)")
        harness.window.isHidden = true
    }
}

private func energyMilliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}
#endif
