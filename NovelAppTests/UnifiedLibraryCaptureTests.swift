import AppKit
import EditorKit
import Foundation
@testable import FUMINIWA
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Runtime
import SwiftUI
import Testing

/// Isolated view renders, not screenshots of the user's running application.
@MainActor
@Suite(.serialized)
struct UnifiedLibraryCaptureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FUMINIWA_UNIFIED_LIBRARY_CAPTURE"] == "1"))
    func renderShelfAndRoundTrip() async throws {
        for dark in [false, true] {
            for display in ["grid", "list"] {
                let fixture = try TestRuntimeConfiguration(account: nil)
                let state = AppState(dependencies: AppDependencies(
                    userDefaults: makeIsolatedTestUserDefaults(),
                    snapshotSyncV2Factory: { try await SnapshotSyncV2Runtime.makeApplication(mode: .test(fixture)) }
                ))
                #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
                state.userDefaults.set(display, forKey: "library.display")
                let remote = WorkID(UUID())
                let importing = WorkID(UUID())
                state.lastStartupLibraryConnection = .available
                state.snapshotSyncLibraryWorks = [
                    .init(id: remote.rawValue, title: "海辺の便り", availability: .remoteOnly,
                          workID: remote, remoteProgress: .idle, accountState: .active),
                    .init(id: importing.rawValue, title: "季節の記録", availability: .remoteOnly,
                          workID: importing, remoteProgress: .idle, accountState: .active)
                ]
                state.snapshotSyncV2RemoteOnlyOpeningWorkID = importing
                state.snapshotSyncV2RemoteOnlyOpenStartedAt = Date()
                state.workspaceModel.libraryImportPhases[importing] = .init(receivedBytes: 8_200_000, totalBytes: 19_000_000)
                state.startupState = .documentSelection(.init(works: state.snapshotSyncLibraryWorks,
                                                              presentation: .localAndRemote, connection: .available))
                let suffix = "\(display)-\(dark ? "dark" : "light")"
                try await capture(LibraryView(observesLibrary: false).environment(state).environment(state.workspaceModel)
                    .environment(DocumentPanelPresenter(appState: state)).defaultAppStorage(state.userDefaults)
                    .preferredColorScheme(dark ? .dark : .light), name: suffix)
                state.lastStartupLibraryConnection = .available
                state.lastStartupLibraryConnection = .accountRequired
                state.snapshotSyncLibraryWorks = []
                state.startupState = .documentSelection(.init(works: [], presentation: .localAndRemote,
                                                              connection: .accountRequired))
                try await capture(LibraryView(observesLibrary: false).environment(state).environment(state.workspaceModel)
                    .environment(DocumentPanelPresenter(appState: state)).defaultAppStorage(state.userDefaults)
                    .preferredColorScheme(dark ? .dark : .light), name: "empty-\(suffix)")
                if display == "grid" {
                    state.startupState = .loading
                    try await capture(LibraryView(observesLibrary: false).environment(state).environment(state.workspaceModel)
                        .environment(DocumentPanelPresenter(appState: state)).defaultAppStorage(state.userDefaults)
                        .preferredColorScheme(dark ? .dark : .light), name: "loading-\(suffix)")
                }
            }
        }
        let configuration = try TestRuntimeConfiguration(account: nil)
        let state = AppState(dependencies: AppDependencies(
            userDefaults: makeIsolatedTestUserDefaults(),
            snapshotSyncV2Factory: { try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration)) }
        ))
        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()
        state.workspaceModel.document.title = "窓辺の手紙"
        state.markDocumentDirty()
        #expect(await state.saveNow())
        let application = try #require(state.snapshotSyncV2Application)
        let second = WorkID(UUID())
        _ = try await application.checkpoint(workID: second, document: .newDocument(title: "雨あがりの庭"),
                                             reason: .migration, documentCreatedAt: Date())
        let root = ContentView().environment(state).environment(state.workspaceModel)
            .environment(EditorSettings(userDefaults: state.userDefaults, appearanceApplier: { _ in }))
            .environment(DocumentPanelPresenter(appState: state))
            .environment(SnapshotMenuPresenter(appState: state)).environment(ExportPresenter(appState: state))
            .environment(EditorSearchSession()).environment(state.editorCommandSession)
            .defaultAppStorage(state.userDefaults).preferredColorScheme(.light)
        try await capture(root, name: "roundtrip-1-workbench")
        #expect(await state.returnToSnapshotLibrary())
        await state.refreshSnapshotLibrary()
        try await capture(root, name: "roundtrip-2-library")
        let row = try #require(state.snapshotSyncLibraryWorks.first { $0.workID == second })
        #expect(await state.openLibraryWork(row))
        #expect(state.workspaceModel.document.title == "雨あがりの庭")
        try await capture(root, name: "roundtrip-3-other-work")
    }

    private func capture(_ view: some View, name: String) async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/fuminiwa-unified-library")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
