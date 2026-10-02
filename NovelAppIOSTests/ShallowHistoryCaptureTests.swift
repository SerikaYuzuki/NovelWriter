import Foundation
@testable import FUMINIWAIOS
import NovelCore
import NovelSyncV2
import NovelSyncV2Application
import NovelSyncV2Store
import NovelUI
import SwiftUI
import Testing
import UIKit

@Suite("D-106 iOS history captures", .serialized)
@MainActor
struct ShallowHistoryCaptureTests {
    @Test func fetchWaitKeepsEditingAndRestoresOnlyAfterConfirmation() async throws {
        let fixture = try await ShallowCaptureFixture.make()
        defer { fixture.cleanup() }
        let application = try #require(fixture.store.snapshotSyncV2Application)
        let barrier = HistoryCaptureBarrier()
        let local = fixture.local
        let snapshots = fixture.snapshots
        let binding = fixture.binding
        let head = fixture.head
        await fixture.configuration.remote.setHistoryBackfillHandler { workID, manual, progress in
            guard let journal = try await local.resumeBackfill(workID: workID, binding: binding, manual: manual) else { return }
            await barrier.started()
            while await !barrier.released {
                try await Task.sleep(for: .milliseconds(5))
            }
            try await local.applyBackfillPage(V2BackfillPage(snapshots: Array(snapshots.dropLast().reversed()), resumeCursor: nil, terminal: true),
                                              workID: workID, binding: binding, root: head.snapshotId, expectedCursor: journal.resumeCursor)
            await progress()
        }
        _ = try await application.fetchHistoryNow(workID: fixture.workID)
        for _ in 0 ..< 100 {
            if await barrier.isStarted {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await barrier.isStarted)
        fixture.store.updateDocumentTitle("取得中の追記")
        #expect(await fixture.store.saveNow())
        #expect(try await local.open(workID: fixture.workID, scope: .bound(binding)).document?.title == "取得中の追記")
        #expect(try await !local.pendingIntents(scope: .bound(binding), workID: fixture.workID).isEmpty)
        await barrier.release()
        let selected = snapshots[0].snapshotId
        for _ in 0 ..< 100 {
            if try await application.historySnapshotAvailability(workID: fixture.workID, snapshotID: selected) == .local {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await application.historySnapshotAvailability(workID: fixture.workID, snapshotID: selected) == .local)
        #expect(fixture.store.document.title == "取得中の追記")
        #expect(await fixture.store.restoreSnapshotSyncV2(snapshotID: selected.rawValue))
        #expect(fixture.store.document.title == "海辺の便り")
        _ = await application.beginAccountTransitionRemoteSuspension()
        await local.close()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FUMINIWA_SHALLOW_CAPTURE"] == "1"))
    func captureHistoryAndRestore() async throws {
        let fixture = try await ShallowCaptureFixture.make()
        defer { fixture.cleanup() }
        let application = try #require(fixture.store.snapshotSyncV2Application)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shallow-step3")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await fixture.configuration.remote.setHistoryBackfillHandler { _, _, _ in
            while true {
                try await Task.sleep(for: .seconds(1))
            }
        }
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            try await fixture.local.setBackfillStatus(workID: fixture.workID, binding: fixture.binding, status: .paused)
            _ = try await application.fetchHistoryNow(workID: fixture.workID)
            try await capture(NavigationStack { IOSSnapshotHistoryView(store: fixture.store) }, dark: dark,
                              url: directory.appendingPathComponent("history-unfetched-\(suffix).png"))
            await application.setHistoryBackfillNetwork(online: false, constrained: false)
            try await capture(NavigationStack { IOSSnapshotHistoryView(store: fixture.store) }, dark: dark,
                              url: directory.appendingPathComponent("history-offline-\(suffix).png"))
            let suspension = await application.beginAccountTransitionRemoteSuspension()
            _ = await application.endAccountTransitionRemoteSuspension(suspension, resume: false)
            await application.setHistoryBackfillNetwork(online: true, constrained: true)
            let restore = HistoryFetchControls(application: application, workID: fixture.workID,
                                               snapshotID: fixture.snapshots[0].snapshotId,
                                               rowDate: Date(timeIntervalSince1970: 1_780_000_000), rowKind: "手動保存").presentingRestoreForCapture()
            try await capture(NavigationStack { List { restore }.navigationTitle("履歴") }, dark: dark,
                              url: directory.appendingPathComponent("restore-unfetched-\(suffix).png"))
            await application.setHistoryBackfillNetwork(online: true, constrained: false)
            try await fixture.local.setBackfillStatus(workID: fixture.workID, binding: fixture.binding, status: .paused, failureCode: "interrupted")
            try await capture(NavigationStack { IOSSnapshotHistoryView(store: fixture.store) }, dark: dark,
                              url: directory.appendingPathComponent("failure-retry-\(suffix).png"))
            try await fixture.local.setBackfillStatus(workID: fixture.workID, binding: fixture.binding, status: .failed, failureCode: "invalidRemoteData")
            try await capture(NavigationStack { IOSSnapshotHistoryView(store: fixture.store) }, dark: dark,
                              url: directory.appendingPathComponent("validation-failure-\(suffix).png"))
            fixture.store.syncV2LibraryItems = [SyncV2LibraryItem(workID: fixture.workID, title: "海辺の便り", availability: .cached, accountState: .active)]
            fixture.store.applySnapshotSyncV2State(SyncUIState(workID: fixture.workID,
                                                               localDurability: .saved(generation: 1, snapshotID: fixture.head.snapshotId),
                                                               remoteProgress: .retryable(.historyIncomplete), conflict: nil, lastTypedResult: .queued))
            let home = NavigationStack {
                IOSProjectHomeView(store: fixture.store, openWriting: {}, openProjectInfo: {}, openPlot: {}, openCharacters: {},
                                   openWorldbuilding: {}, openFeedback: {}, openReferences: {}, openSettings: {})
            }
            try await capture(home, dark: dark, url: directory.appendingPathComponent("work-home-\(suffix).png"))
            try await capture(home, dark: dark, url: directory.appendingPathComponent("conflict-waiting-\(suffix).png"), scrollToBottom: true)
        }
        _ = await application.beginAccountTransitionRemoteSuspension()
        await fixture.local.close()
        print("SHALLOW_CAPTURE_DIRECTORY=\(directory.path)")
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        let own = (view as? UIScrollView).map { [$0] } ?? []
        return own + view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func capture(_ view: some View, dark: Bool, url: URL, scrollToBottom: Bool = false) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 440, height: 956)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        let host = UIHostingController(rootView: view.preferredColorScheme(dark ? .dark : .light)
            .tint(FuminiwaColor.accent.color))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(550))
        host.view.layoutIfNeeded()
        if scrollToBottom, let scroll = scrollViews(in: host.view).max(by: { $0.contentSize.height < $1.contentSize.height }) {
            let bottom = max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
            try await Task.sleep(for: .milliseconds(150))
        }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let data = try #require(image.pngData())
        try data.write(to: url)
    }
}

@MainActor
struct ShallowCaptureFixture {
    let configuration: TestRuntimeConfiguration
    let local: LocalSyncV2Store
    let store: IOSDocumentStore
    let snapshots: [EncodedSnapshot]
    let binding: V2AccountBinding
    var head: EncodedSnapshot {
        snapshots[snapshots.count - 1]
    }

    var workID: WorkID {
        head.manifest.workId
    }

    static func make() async throws -> Self {
        let configuration = try TestRuntimeConfiguration()
        let defaults = try #require(UserDefaults(suiteName: configuration.defaults.suiteName))
        let local = try LocalSyncV2Store(root: configuration.localRoot.url, policy: .createNew)
        let binding = V2AccountBinding(accountID: "test-account", accountFence: "test-fence", serverInstanceID: "test-server")
        let workID = WorkID(UUID())
        var document = NovelDocument.newDocument(title: "海辺の便り")
        var snapshots: [EncodedSnapshot] = []
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        for index in 0 ..< 4 {
            document.chapters[0].episodes[0].content = "図書室に届いた手紙。第\(index + 1)稿。"
            try snapshots.append(SnapshotCodec.encode(SnapshotModel(workId: workID, document: document, documentCreatedAt: date),
                                                      parents: snapshots.last.map { [$0.snapshotId] } ?? []))
        }
        let head = try #require(snapshots.last)
        let remoteHead = try V2RemoteHead(snapshotID: head.snapshotId, generation: 1)
        try await local.installShallowHead(V2RemoteSnapshotGraph(workID: workID, headSnapshotID: head.snapshotId, snapshots: [head],
                                                                 expectedCurrentSnapshotID: nil, expectedLocalGeneration: 0,
                                                                 expectedRemoteHead: remoteHead), scope: .bound(binding))
        let entries = snapshots.reversed().enumerated().map { index, snapshot in
            SyncV2RemoteHistoryEntry(occurrenceID: UUID(), snapshotID: snapshot.snapshotId, reason: "explicit", pinned: false,
                                     createdAt: date.addingTimeInterval(Double(-index * 3600)))
        }
        await configuration.remote.setHistoryEntries(entries, workID: workID)
        let store = IOSDocumentStore(userDefaults: defaults, libraryRoot: configuration.localRoot.url, runtimeComposition: .test(configuration))
        await store.bootstrap()
        #expect(await store.openSnapshotSyncV2(workID: workID.rawValue))
        return Self(configuration: configuration, local: local, store: store, snapshots: snapshots, binding: binding)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: configuration.localRoot.url)
        UserDefaults.standard.removePersistentDomain(forName: configuration.defaults.suiteName)
    }
}

private actor HistoryCaptureBarrier {
    var isStarted = false
    var released = false
    func started() {
        isStarted = true
    }

    func release() {
        released = true
    }
}
