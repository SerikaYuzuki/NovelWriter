import Foundation
#if os(macOS)
import AppKit
@testable import FUMINIWA
#else
@testable import FUMINIWAIOS
import UIKit
#endif
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Runtime
import SwiftUI
import Testing

@MainActor
@Suite(.serialized)
struct SnapshotConflictPresentationTests {
    @Test func captureSharedSheet() async throws {
        let configuration = try TestRuntimeConfiguration()
        defer {
            UserDefaults.standard.removePersistentDomain(forName: configuration.defaults.suiteName)
        }
        try await captureFixture(configuration)
    }

    private func captureFixture(_ configuration: TestRuntimeConfiguration) async throws {
        let app = try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
        let workID = WorkID(UUID())
        var document = NovelDocument.newDocument(title: "競合の画面確認")
        document.chapters[0].episodes[0].title = "届いた手紙"
        document.chapters[0].episodes[0].content = String(repeating: "文", count: 310)
        _ = try await app.checkpoint(workID: workID, document: document, reason: .explicit,
                                     documentCreatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let local = try #require(try await app.currentSnapshotID(workID: workID))
        document.chapters[0].episodes[0].content = "文"
        _ = try await app.checkpoint(workID: workID, document: document, reason: .explicit,
                                     documentCreatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let remote = try #require(try await app.currentSnapshotID(workID: workID))
        await configuration.remote.setHistoryEntries([
            SyncV2RemoteHistoryEntry(occurrenceID: UUID(), snapshotID: remote, reason: "explicit", pinned: false, createdAt: Date())
        ], workID: workID)
        let conflict = SyncV2ConflictProjection(conflictID: UUID(), revision: 1, baseSnapshotID: nil,
                                                localSnapshotID: local, remoteSnapshotID: remote, sourceGeneration: 1)
        for dark in [false, true] {
            let view = ConflictSheet(application: app, workID: workID, conflict: conflict,
                                     deviceLabel: "この端末") { _ in true } cancel: {}
                .preferredColorScheme(dark ? .dark : .light)
            try await capture(view, name: "conflict-\(dark ? "dark" : "light")")
        }
        let confirmation = ConflictSheet(application: app, workID: workID, conflict: conflict,
                                         deviceLabel: "この端末") { _ in true } cancel: {}
            .presentingReductionForCapture()
        try await capture(confirmation, name: "reduction-confirmation")
        _ = await app.beginAccountTransitionRemoteSuspension()
    }

    private func capture(_ view: some View, name: String) async throws {
        #if os(macOS)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(600))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let url = URL(fileURLWithPath: "/tmp/fuminiwa-run2-\(name).png")
        try data.write(to: url)
        print("CONFLICT_CAPTURE=\(url.path)")
        window.contentView = nil
        window.close()
        #else
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 440, height: 956)
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(600))
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fuminiwa-run2-\(name).png")
        try #require(image.pngData()).write(to: url)
        print("CONFLICT_CAPTURE=\(url.path)")
        window.isHidden = true
        window.rootViewController = nil
        #endif
    }
}
