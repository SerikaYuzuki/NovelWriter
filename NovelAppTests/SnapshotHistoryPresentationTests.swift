import Foundation
#if os(macOS)
import AppKit
@testable import FUMINIWA
#else
@testable import FUMINIWAIOS
import UIKit
#endif
import NovelSyncV2
import NovelSyncV2Application
import SwiftUI
import Testing

@MainActor
@Suite(.serialized)
struct SnapshotHistoryPresentationTests {
    private func entries() throws -> [SyncV2HistoryItem] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let snapshotID = try SnapshotID(rawValue: String(repeating: "a", count: 64))
        var result: [SyncV2HistoryItem] = []
        for day in 0 ..< 3 {
            let start = calendar.date(byAdding: .day, value: -day, to: today)!
            for index in 0 ..< 14 {
                let date = start.addingTimeInterval(Double(36000 + index * 180))
                result.append(SyncV2HistoryItem(
                    occurrenceID: UUID(), snapshotID: snapshotID,
                    reason: index == 12 ? "explicit" : "autosave", pinned: index == 12,
                    localGeneration: nil, createdAt: date,
                    source: .local, localAvailability: .available, onlineAvailability: .unavailable
                ))
            }
        }
        return result
    }

    #if os(macOS)
    @Test func staleRestoreRequestIsRejected() async throws {
        let state = AppState(dependencies: AppDependencies(userDefaults: makeIsolatedTestUserDefaults()))
        let presenter = SnapshotMenuPresenter(appState: state)
        let request = try SnapshotRestoreRequest(entry: entries()[0], session: state.documentSessionToken)
        presenter.requestRestore(request)
        #expect(presenter.snapshotPendingRestore == nil)
        await presenter.restore(request)
        #expect(presenter.restoreErrorMessage != nil)
    }

    @Test func capturePopover() async throws {
        let state = AppState(dependencies: AppDependencies(userDefaults: makeIsolatedTestUserDefaults()))
        let presenter = SnapshotMenuPresenter(appState: state)
        for dark in [false, true] {
            let view = SnapshotPopover(overlayState: WorkbenchOverlayState())
                .environment(state).environment(presenter)
                .frame(width: 420, height: 560)
                .background(Color(nsColor: .windowBackgroundColor))
                .preferredColorScheme(dark ? .dark : .light)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(300))
            presenter.snapshots = try entries().map { SnapshotRestoreRequest(
                entry: $0,
                session: state.documentSessionToken
            ) }
            try await Task.sleep(for: .milliseconds(400))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            let path = "/tmp/fuminiwa-snapshot-popover-\(dark ? "dark" : "light").png"
            try data.write(to: URL(fileURLWithPath: path))
            print("HISTORY_CAPTURE=\(path)")
            window.contentView = nil
            window.close()
        }
    }
    #else
    @Test func captureIOSHistory() async throws {
        let fixture = try await ShallowCaptureFixture.make()
        defer { fixture.cleanup() }
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        for dark in [false, true] {
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 440, height: 956)
            let host = UIHostingController(rootView: NavigationStack { IOSSnapshotHistoryView(store: fixture.store) }
                .preferredColorScheme(dark ? .dark : .light))
            window.rootViewController = host
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(300))
            fixture.store.syncV2HistoryItems = try entries()
            try await Task.sleep(for: .milliseconds(400))
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("fuminiwa-snapshot-ios-\(dark ? "dark" : "light").png")
            try #require(image.pngData()).write(to: path)
            print("HISTORY_CAPTURE=\(path.path)")
            window.isHidden = true
        }
        _ = await fixture.store.snapshotSyncV2Application?.beginAccountTransitionRemoteSuspension()
        await fixture.local.close()
    }
    #endif
}
