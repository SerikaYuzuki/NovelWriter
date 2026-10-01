import Foundation
import NovelSyncV2
import NovelSyncV2Application
import SwiftUI

extension IOSDocumentStore {
    func observeLibraryImports() async {
        let account = snapshotSyncV2AccountScope
        while !Task.isCancelled, account == snapshotSyncV2AccountScope {
            if let application = snapshotSyncV2Application {
                let state = await application.importStates()
                guard !Task.isCancelled, account == snapshotSyncV2AccountScope else { return }
                var phases = state.phases
                if let opening = snapshotSyncV2RemoteOnlyOpeningWorkID,
                   phases[opening] == nil, libraryImportPhases[opening]?.stage == .opening {
                    phases[opening] = libraryImportPhases[opening]
                }
                libraryImportPhases = phases
                libraryImportFailures = state.failures
            }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
    }

    func cancelLibraryImport() async {
        let id = libraryPrefetchWorkID ?? snapshotSyncV2RemoteOnlyOpeningWorkID
        libraryPrefetchTask?.cancel()
        snapshotSyncV2RemoteOnlyOpenTask?.cancel()
        if let id {
            await snapshotSyncV2Application?.cancelImport(workID: id)
        }
        if let task = snapshotSyncV2RemoteOnlyOpenTask {
            _ = await task.value
        }
        if let task = libraryPrefetchTask {
            await task.value
        }
        _ = await refreshLibrary()
    }

    func takeOntoDevice(workID: WorkID, title: String) {
        guard libraryPrefetchTask == nil, snapshotSyncV2RemoteOnlyOpenTask == nil,
              let application = snapshotSyncV2Application else { return }
        let account = snapshotSyncV2AccountScope
        libraryPrefetchWorkID = workID
        snapshotSyncV2RemoteOnlyOpenStartedAt = Date()
        libraryPrefetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                libraryPrefetchTask = nil
                libraryPrefetchWorkID = nil
                if snapshotSyncV2RemoteOnlyOpenTask == nil {
                    snapshotSyncV2RemoteOnlyOpenStartedAt = nil
                }
            }
            do {
                try await prefetchWithBackgroundTime(application, workID: workID)
                guard !Task.isCancelled, account == snapshotSyncV2AccountScope else { return }
                _ = await refreshLibrary()
                AccessibilityNotification.Announcement("『\(title)』をこの端末に取り込みました").post()
            } catch {
                guard !Task.isCancelled, account == snapshotSyncV2AccountScope else { return }
                libraryImportFailures[workID] = syncV2FailureKind(error)
                AccessibilityNotification.Announcement(SyncV2LibraryPresentation.importFailure(syncV2FailureKind(error))).post()
            }
        }
    }
}
