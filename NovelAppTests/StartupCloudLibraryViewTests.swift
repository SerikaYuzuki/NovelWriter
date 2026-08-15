import AppKit
import Foundation
@testable import FUMINIWA
import NovelStorage
import SwiftUI
import Testing

@MainActor
@Suite("Cloud library startup view")
struct StartupCloudLibraryViewTests {
    @Test("単一pane作品棚は実NSHostingViewでpathなしにlayoutできる")
    func simpleShelfLaysOutWithoutPaths() throws {
        let context = StartupDocumentSelectionContext(
            works: [
                StartupLibraryWork(
                    reference: .cloudWork(UUID()),
                    title: "夜の庭",
                    updatedAt: Date(timeIntervalSince1970: 1),
                    availability: .cachedRemote
                ),
                StartupLibraryWork(
                    reference: .cloudWork(UUID()),
                    title: "地下鉄の草稿",
                    updatedAt: nil,
                    availability: .localPending
                ),
                StartupLibraryWork(
                    reference: .cloudWork(UUID()),
                    title: "三国志のも",
                    updatedAt: Date(timeIntervalSince1970: 2),
                    availability: .needsReview
                )
            ],
            connection: .available,
            isLoading: true
        )
        let defaultsName = "FUMINIWA.StartupCloudLibraryViewTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defaults.removePersistentDomain(forName: defaultsName)
        let state = AppState(
            dependencies: AppDependencies(
                repository: NovelpkgRepository(),
                userDefaults: defaults
            ),
            initialStartupState: .documentSelection(context)
        )
        let presenter = DocumentPanelPresenter(appState: state)
        let host = NSHostingView(rootView: StartupDocumentSelectionView(context: context)
            .environment(state)
            .environment(presenter))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 620)
        host.layoutSubtreeIfNeeded()

        #expect(host.fittingSize.width >= 720)
        #expect(host.fittingSize.height >= 520)
        #expect(context.presentation == .cloudLibrary)
        #expect(context.works.allSatisfy { work in
            if case .cloudWork = work.reference {
                true
            } else {
                false
            }
        })
        #expect(context.works.map(\.title).allSatisfy { !$0.contains("/") })
    }
}
