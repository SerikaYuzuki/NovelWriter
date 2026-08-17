import Foundation
import NovelCore
import NovelSyncV2
import NovelSyncV2Application

/// macOSのv2作品棚とremote catalogの投影。
extension AppState {
    private var permitsLibraryWorkOpening: Bool {
        guard !isDocumentTransitionInProgress, !isTerminationPending else { return false }
        switch startupState {
        case .ready, .documentSelection:
            return true
        case .loading, .recovery:
            return false
        }
    }

    func refreshSnapshotLibrary() async {
        guard let application = snapshotSyncV2Application else { return }
        let shouldPresentSelection = !startupState.isReady
        let connection: StartupLibraryConnection = switch authUIState {
        case .signedIn: .available
        case .signedOut, .unavailable, .signingIn, .failed: .offline
        }
        lastStartupLibraryConnection = connection
        guard let projection = try? await application.library() else {
            // A transient local read failure must not erase the last verified
            // shelf. The cached projection remains usable offline and is
            // refreshed on the next explicit/background read.
            if shouldPresentSelection {
                startupState = .documentSelection(
                    .init(
                        works: snapshotSyncLibraryWorks,
                        presentation: .localAndRemote,
                        connection: connection
                    )
                )
            }
            return
        }
        snapshotSyncCurrentWorkAccountState = currentSnapshotSyncV2WorkID.flatMap { workID in
            projection.items.first(where: { $0.workID == workID })?.accountState
        }
        var worksByID = Dictionary(uniqueKeysWithValues: projection.items.compactMap { item -> (WorkID, StartupLibraryWork)? in
            guard item.accountState == .active || item.accountState == .unbound else { return nil }
            let availability: StartupLibraryWorkAvailability = switch item.availability {
            case .localOnly: .local
            case .cached: .cached
            case .remoteOnly: .remoteOnly
            }
            let withConflict = item.conflict != nil || item.remoteProgress == .needsChoice
            let work = StartupLibraryWork(
                id: item.workID.rawValue,
                title: item.title,
                availability: withConflict ? .conflict : availability,
                workID: item.workID,
                remoteProgress: item.remoteProgress
            )
            return (item.workID, work)
        })
        for remote in snapshotSyncRemoteCatalogItems {
            if let local = worksByID[remote.workID] {
                let availability: StartupLibraryWorkAvailability = local.availability == .conflict
                    ? .conflict
                    : .cached
                worksByID[remote.workID] = StartupLibraryWork(
                    id: remote.workID.rawValue,
                    title: local.title.isEmpty ? remote.title : local.title,
                    availability: availability,
                    workID: remote.workID,
                    remoteProgress: local.remoteProgress
                )
            } else {
                worksByID[remote.workID] = StartupLibraryWork(
                    id: remote.workID.rawValue,
                    title: remote.title,
                    availability: .remoteOnly,
                    workID: remote.workID,
                    remoteProgress: .idle
                )
            }
        }
        let works = worksByID.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        snapshotSyncLibraryWorks = works
        if shouldPresentSelection {
            startupState = .documentSelection(.init(works: works, presentation: .localAndRemote, connection: connection))
        }
    }

    /// Refresh the account-scoped remote catalog in the background. The
    /// provider performs account/fence filtering; this layer only deduplicates
    /// by WorkID and merges the result into the local shelf.
    func refreshSnapshotRemoteCatalog() async {
        guard let application = snapshotSyncV2Application,
              case .signedIn = authUIState else { return }
        do {
            var cursor: String?
            var items: [SyncV2RemoteCatalogEntry] = []
            repeat {
                let page = try await application.refreshRemoteCatalog(
                    cursor: cursor,
                    pageSize: 100
                )
                items.append(contentsOf: page.items)
                cursor = page.nextCursor
            } while cursor != nil
            snapshotSyncRemoteCatalogItems = items.reduce(into: [:]) { result, item in
                result[item.workID] = item
            }.values.sorted {
                $0.workID.description < $1.workID.description
            }
            await refreshSnapshotLibrary()
        } catch {
            // Offline catalog reads leave the verified local shelf intact.
        }
    }

    /// Workbench の「作品一覧」境界。表示中のEditorをIME確定し、dirtyなら
    /// SQLite checkpointだけを完了してから一覧へ戻る。remote workerは共有
    /// application側へ委譲し、この遷移では待たない。
    @discardableResult
    func returnToSnapshotLibrary() async -> Bool {
        guard snapshotSyncV2Application != nil,
              permitsDocumentChoice else { return false }
        let returned = await documentOperationGate.perform { [weak self] in
            guard let self,
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            isDocumentTransitionInProgress = true
            defer { isDocumentTransitionInProgress = false }

            if saveState != .saved {
                guard await saveNow() else { return false }
            }
            startupState = .documentSelection(
                .init(
                    works: snapshotSyncLibraryWorks,
                    presentation: .localAndRemote,
                    connection: lastStartupLibraryConnection
                )
            )
            return true
        }
        guard returned else { return false }

        // Refresh the local shelf after the gate releases. The read is local
        // SQLite/catalog projection; it must not hold the editor transition or
        // make this public boundary await an HTTP worker.
        Task { @MainActor [weak self] in
            await self?.refreshSnapshotLibrary()
        }
        return true
    }

    @discardableResult
    func openLibraryWork(_ work: StartupLibraryWork) async -> Bool {
        guard let application = snapshotSyncV2Application,
              work.isOpenable,
              permitsLibraryWorkOpening else { return false }
        return await documentOperationGate.perform { [weak self] in
            guard let self,
                  editorCommandSession.prepareForDocumentTransition() else { return false }
            defer { editorCommandSession.resumeAfterDocumentTransition() }
            isDocumentTransitionInProgress = true
            defer { isDocumentTransitionInProgress = false }
            if saveState != .saved {
                guard await saveNow() else { return false }
            }
            do {
                let opened = try await application.open(workID: work.workID)
                guard let openedDocument = opened.document else { return false }
                installV2Document(
                    openedDocument,
                    workID: opened.workID,
                    createdAt: opened.documentCreatedAt,
                    attachments: opened.attachments,
                    resources: opened.resources
                )
                snapshotSyncV2Session = await application.beginSession(workID: opened.workID)
                startupState = .ready
                await refreshSnapshotSyncV2UIState()
                return true
            } catch {
                return false
            }
        }
    }
}
