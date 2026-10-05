import AppKit
import Foundation
@testable import FUMINIWA
import SwiftUI
import Testing

@MainActor
@Suite(.serialized)
struct LibraryShelfCaptureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FUMINIWA_LIBRARY_CAPTURE"] == "1"))
    func captureEmptyStates() async throws {
        for mode in ["offline", "empty"] {
            let state = AppState(dependencies: AppDependencies(userDefaults: makeIsolatedTestUserDefaults()))
            state.workspaceModel.libraryFailure = mode == "offline" ? .offline : nil
            state.startupState = .documentSelection(.init(works: [], presentation: .localAndRemote,
                                                          connection: mode == "offline" ? .offline : .accountRequired))
            state.lastStartupLibraryConnection = mode == "offline" ? .offline : .accountRequired
            let view = LibraryView().environment(state).environment(state.workspaceModel)
                .environment(DocumentPanelPresenter(appState: state)).preferredColorScheme(.light)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "FUMINIWA 棚プレビュー \(mode)"
            window.contentView = NSHostingView(rootView: view)
            window.center()
            window.makeKeyAndOrderFront(nil)
            defer { window.contentView = nil; window.close() }
            try await Task.sleep(for: .milliseconds(350))
            let path = "/tmp/fuminiwa-shelf-macos-\(mode).png"
            let marker = path + ".captured"
            try? FileManager.default.removeItem(atPath: marker)
            let request = ["windowID": String(window.windowNumber), "path": path]
            try JSONSerialization.data(withJSONObject: request)
                .write(to: URL(fileURLWithPath: "/tmp/fuminiwa-shelf-capture-request.json"))
            for _ in 0 ..< 300 {
                if FileManager.default.fileExists(atPath: marker) {
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(FileManager.default.fileExists(atPath: marker))
        }
    }
}
