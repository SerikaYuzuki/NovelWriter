import AppKit
import Foundation
@testable import FUMINIWA
import NovelCore
import NovelSyncV2Application
import NovelSyncV2Runtime
import Testing

@MainActor
struct ApplicationDelegateTests {
    @Test("cold launchのnovelpkgはbootstrap用に一度だけ保持する")
    func queuesColdLaunchDocument() {
        let delegate = ApplicationDelegate()
        let ignoredURL = URL(fileURLWithPath: "/tmp/readme.txt")
        let packageURL = URL(fileURLWithPath: "/tmp/Finder作品.novelpkg")

        delegate.application(NSApplication.shared, open: [ignoredURL, packageURL])

        #expect(delegate.takeStartupOpenURL()?.path == packageURL.path)
        #expect(delegate.takeStartupOpenURL() == nil)
    }

    @Test("単一ウィンドウでは最初のnovelpkgだけを採用する")
    func queuesOnlyFirstPackageFromEvent() {
        let delegate = ApplicationDelegate()
        let firstURL = URL(fileURLWithPath: "/tmp/第一候補.novelpkg")
        let secondURL = URL(fileURLWithPath: "/tmp/第二候補.novelpkg")

        delegate.application(NSApplication.shared, open: [firstURL, secondURL])

        #expect(delegate.takeStartupOpenURL()?.path == firstURL.path)
    }

    @Test("重複した終了要求は一つの保存と一度のAppKit replyへ合流する")
    func coalescesConcurrentTerminationReplies() async throws {
        let delegate = ApplicationDelegate()
        let suiteName = "FUMINIWAApplicationDelegateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let state = AppState(
            dependencies: AppDependencies(userDefaults: defaults),
            initialStartupState: .ready
        )
        delegate.attach(appState: state)
        var replies: [Bool] = []

        #expect(delegate.beginTerminationRequest { replies.append($0) } == .terminateLater)
        #expect(delegate.beginTerminationRequest { replies.append($0) } == .terminateLater)
        while replies.isEmpty {
            await Task.yield()
        }

        #expect(replies == [true])
    }

    @Test("AppStateなしでも終了前準備を完了してからAppKit replyへ進む")
    func awaitsTerminationPreparation() async {
        let delegate = ApplicationDelegate()
        var preparationCompleted = false
        var replies: [Bool] = []
        delegate.attachTerminationPreparation {
            await Task.yield()
            preparationCompleted = true
        }

        #expect(delegate.beginTerminationRequest { replies.append($0) } == .terminateLater)
        while replies.isEmpty {
            await Task.yield()
        }

        #expect(preparationCompleted)
        #expect(replies == [true])
    }

    @Test("保存失敗時はruntimeを止めず、再試行の保存成功後にだけ終了前準備を行う")
    func terminationPreparationRunsOnlyAfterSuccessfulSave() async throws {
        let delegate = ApplicationDelegate()
        let suiteName = "FUMINIWAApplicationDelegateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let configuration = try TestRuntimeConfiguration(account: nil)
        let state = AppState(
            dependencies: AppDependencies(
                userDefaults: defaults,
                snapshotSyncV2Factory: {
                    try await SnapshotSyncV2Runtime.makeApplication(mode: .test(configuration))
                }
            ),
            initialStartupState: .ready
        )
        state.updateSelectedEpisodeContent("終了前に保存する本文")
        delegate.attach(appState: state)

        var preparationCount = 0
        var replies: [Bool] = []
        delegate.attachTerminationPreparation {
            preparationCount += 1
        }

        #expect(delegate.beginTerminationRequest { replies.append($0) } == .terminateLater)
        while replies.isEmpty {
            await Task.yield()
        }
        #expect(replies == [false])
        #expect(preparationCount == 0)

        #expect(await state.configureSnapshotSyncV2(using: state.snapshotSyncV2Factory))
        await state.bootstrap()
        #expect(delegate.beginTerminationRequest { replies.append($0) } == .terminateLater)
        while replies.count < 2 {
            await Task.yield()
        }
        #expect(replies == [false, true])
        #expect(preparationCount == 1)
    }
}
