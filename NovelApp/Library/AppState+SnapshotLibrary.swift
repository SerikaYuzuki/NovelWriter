import Foundation
import NovelCore
import NovelLocalStore
import NovelSync

/// SQLite/Rust snapshot runtime's startup shelf. This is deliberately kept
/// separate from the retired DeviceSync library so a remote work can be
/// discovered even when this Mac has never opened it before.
extension AppState {
    func refreshSnapshotLibrary() async {
        guard usesSnapshotSyncRuntime,
              let store = localCanonicalStore,
              let worker = localSnapshotSyncWorker,
              case let .documentSelection(current) = startupState,
              current.presentation == .cloudLibrary else { return }

        isStartupLibraryOperationInProgress = false
        let localStates: [LocalWorkState]
        do {
            localStates = try await store.allWorkStates()
        } catch {
            snapshotRemoteLibraryEntries = [:]
            startupState = .documentSelection(
                StartupDocumentSelectionContext(
                    works: [],
                    connection: .unavailable(message: "このMacの作品情報を安全に確認できませんでした。")
                )
            )
            return
        }

        var remoteEntries: [SnapshotSyncLibraryEntry] = []
        var connection: StartupLibraryConnection = .available
        switch authUIState {
        case .signedOut, .failed:
            connection = .accountRequired
        case .unavailable:
            connection = .unavailable(message: "サーバー接続を利用できません。")
        case .signingIn:
            connection = .accountRequired
        case .signedIn:
            do {
                remoteEntries = try await worker.library()
                DeviceSyncLog.snapshot("library loaded count=\(remoteEntries.count)")
            } catch SnapshotSyncError.offline {
                connection = .offline
                DeviceSyncLog.snapshot("library offline")
            } catch SnapshotSyncError.unauthorized {
                connection = .accountRequired
                DeviceSyncLog.snapshot("library unauthorized")
            } catch {
                connection = .unavailable(message: "サーバーの作品を更新できませんでした。")
                DeviceSyncLog.snapshot("library failed", error: error)
            }
        }

        let remoteByID = Dictionary(uniqueKeysWithValues: remoteEntries.map { ($0.workID, $0) })
        snapshotRemoteLibraryEntries = remoteByID
        var rows: [StartupLibraryWork] = []
        rows.reserveCapacity(localStates.count + remoteEntries.count)

        for state in localStates {
            let localTitle = await snapshotLocalTitle(state, store: store)
            let remote = remoteByID[state.workID]
            let hasConflict: Bool = if remote != nil {
                await (try? worker.conflicts(workID: state.workID))?.isEmpty == false
            } else {
                false
            }
            let availability: StartupLibraryWorkAvailability = if hasConflict {
                .needsReview
            } else if let remote, state.acknowledgedHeadSnapshotID == remote.head?.snapshotID {
                .cachedRemote
            } else if remote != nil {
                .localPending
            } else {
                .localPending
            }
            rows.append(
                StartupLibraryWork(
                    reference: .cloudWork(state.workID),
                    title: remote?.title ?? localTitle.title,
                    updatedAt: remote.flatMap { _ in localTitle.updatedAt },
                    availability: availability,
                    isTitleTruncated: (remote?.title ?? localTitle.title).utf8.count > 1024
                )
            )
        }

        let localIDs = Set(localStates.map(\.workID))
        for remote in remoteEntries where !localIDs.contains(remote.workID) {
            rows.append(
                StartupLibraryWork(
                    reference: .cloudWork(remote.workID),
                    title: remote.title,
                    updatedAt: nil,
                    availability: .remoteOnly,
                    isTitleTruncated: remote.title.utf8.count > 1024
                )
            )
        }

        lastStartupLibraryConnection = connection
        permitsCloudLibraryMutation = true
        startupState = .documentSelection(
            StartupDocumentSelectionContext(
                works: rows.sorted(by: StartupLibraryProjection.sort),
                connection: connection
            )
        )
    }

    private func snapshotLocalTitle(
        _ state: LocalWorkState,
        store: LocalSQLiteStore
    ) async -> (title: String, updatedAt: Date?) {
        guard let snapshotID = state.currentLocalSnapshotID else {
            return ("名称未設定の作品", nil)
        }
        guard let snapshot = try? await store.snapshot(id: snapshotID) else {
            return ("名称未設定の作品", nil)
        }
        guard
            let manifestObject = try? JSONSerialization.jsonObject(with: snapshot.manifest) as? [String: Any],
            let entries = manifestObject["entries"] as? [[String: Any]],
            let objectID = entries.first(where: { $0["entityKey"] as? String == "work/document" })?["objectId"] as? String,
            let bytes = try? await store.object(id: objectID),
            let document = try? JSONDecoder().decode(WorkSnapshot.self, from: bytes) else {
            return ("名称未設定の作品", snapshot.createdAt)
        }
        return (document.title, snapshot.createdAt)
    }
}
