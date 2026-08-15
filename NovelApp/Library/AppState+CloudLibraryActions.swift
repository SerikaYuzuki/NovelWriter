import Foundation
import NovelCore
import NovelSync

extension AppState {
    var canPublishCurrentWorkToCloud: Bool {
        startupState.isReady &&
            permitsDocumentInteraction &&
            lastStartupLibraryConnection.allowsExplicitCloudPublish &&
            deviceSyncRuntime?.library != nil &&
            !isCurrentWorkBoundToCloud
    }

    var canExplicitlySyncCurrentWork: Bool {
        startupState.isReady &&
            permitsDocumentInteraction &&
            noteSyncClient != nil &&
            isCurrentWorkBoundToCloud &&
            noteSyncConflict == nil
    }

    var isExplicitNoteSyncInFlight: Bool {
        noteSyncClient != nil && workSyncNetworkTask != nil
    }

    func dismissCloudLibraryActionMessage() {
        cloudLibraryActionMessage = nil
    }

    @discardableResult
    func publishStartupLibraryWork(
        _ reference: StartupLibraryWorkReference,
        expectedSession: DocumentSessionToken
    ) async -> Bool {
        guard case let .documentSelection(context) = startupState,
              let work = context.works.first(where: { $0.reference == reference }),
              work.availability.canPublishToCloud(connection: context.connection),
              let workID = work.cloudWorkID,
              permitsCloudLibraryMutation,
              !isStartupLibraryOperationInProgress else { return false }
        isStartupLibraryOperationInProgress = true
        defer { isStartupLibraryOperationInProgress = false }
        let published = await documentOperationGate.perform { [weak self] in
            guard let self, documentSessionToken == expectedSession else { return false }
            return await publishVerifiedLocalLibraryWork(workID)
        }
        // Catalog refresh can wait on CloudKit. Do not keep the chooser disabled
        // (and the retry button gray) after the save itself has finished.
        isStartupLibraryOperationInProgress = false
        await refreshStartupLibrary()
        return published
    }

    @discardableResult
    func publishCurrentLibraryWork(
        expectedSession: DocumentSessionToken
    ) async -> Bool {
        guard canPublishCurrentWorkToCloud,
              documentSessionToken == expectedSession,
              let library = deviceSyncRuntime?.library else { return false }
        DeviceSyncLog.event("publish begin workbench")
        let published = await documentOperationGate.perform { [weak self] in
            guard let self,
                  documentSessionToken == expectedSession,
                  startupState.isReady else { return false }
            do {
                guard let workID = try await library.workIDForPackageURL(documentURL) else {
                    return false
                }
                try await library.validateInstalledPackage(workID)
                let url = try await library.packageURL(workID)
                guard let portable = portableDocumentRepository() else {
                    return false
                }
                let document = try await portable.validatePortablePackage(at: url)
                try await library.publishNewWork(workID, document, url)
                DeviceSyncLog.event("publish ok")
                return true
            } catch {
                presentCloudLibraryActionFailure(
                    error,
                    message: "iCloudへ保存できませんでした。このMacの作品はそのまま残っています。"
                )
                return false
            }
        }
        if published {
            isCurrentWorkBoundToCloud = true
            scheduleActiveDeviceSyncPreparation()
        }
        return published
    }

    @discardableResult
    func duplicateStartupLibraryWork(
        _ reference: StartupLibraryWorkReference,
        expectedSession: DocumentSessionToken
    ) async -> Bool {
        guard case let .documentSelection(context) = startupState,
              let work = context.works.first(where: { $0.reference == reference }),
              work.availability.canDuplicateLocalCopy,
              let workID = work.cloudWorkID,
              permitsCloudLibraryMutation,
              !isStartupLibraryOperationInProgress else { return false }
        isStartupLibraryOperationInProgress = true
        defer { isStartupLibraryOperationInProgress = false }
        let duplicated = await documentOperationGate.perform { [weak self] in
            guard let self,
                  documentSessionToken == expectedSession,
                  case .documentSelection = startupState else { return false }
            return await duplicateVerifiedLocalLibraryWork(workID)
        }
        isStartupLibraryOperationInProgress = false
        await refreshStartupLibrary()
        return duplicated
    }

    @discardableResult
    func removeLocalStartupLibraryWork(
        _ reference: StartupLibraryWorkReference,
        expectedSession: DocumentSessionToken
    ) async -> Bool {
        guard case let .documentSelection(context) = startupState,
              let work = context.works.first(where: { $0.reference == reference }),
              work.availability.canRemoveLocalCopy,
              let workID = work.cloudWorkID,
              permitsCloudLibraryMutation,
              !isStartupLibraryOperationInProgress else { return false }
        isStartupLibraryOperationInProgress = true
        defer { isStartupLibraryOperationInProgress = false }
        let removed = await documentOperationGate.perform { [weak self] in
            guard let self,
                  documentSessionToken == expectedSession,
                  case .documentSelection = startupState,
                  let library = deviceSyncRuntime?.library else { return false }
            do {
                try await library.removeLocalWork(workID)
                return true
            } catch {
                presentCloudLibraryActionFailure(
                    error,
                    message: "このMacの作品を外せませんでした。"
                )
                return false
            }
        }
        isStartupLibraryOperationInProgress = false
        await refreshStartupLibrary()
        return removed
    }

    private func publishVerifiedLocalLibraryWork(
        _ workID: SyncWorkID
    ) async -> Bool {
        DeviceSyncLog.event("publish begin chooser")
        guard let library = deviceSyncRuntime?.library,
              let portable = portableDocumentRepository() else {
            DeviceSyncLog.event("publish skipped chooser missing runtime")
            return false
        }
        do {
            try await library.validateInstalledPackage(workID)
            let url = try await library.packageURL(workID)
            let document = try await portable.validatePortablePackage(at: url)
            if startupState.isReady,
               documentURL.standardizedFileURL == url.standardizedFileURL {
                DeviceSyncLog.event("publish path workbench-document")
                try await library.publishNewWork(workID, document, url)
            } else {
                DeviceSyncLog.event("publish path chooser-resume")
                try await library.resumeInitialWorkPublication(workID, document, url)
            }
            DeviceSyncLog.event("publish ok")
            return true
        } catch {
            presentCloudLibraryActionFailure(
                error,
                message: "iCloudへ保存できませんでした。このMacの作品はそのまま残っています。"
            )
            return false
        }
    }

    private func duplicateVerifiedLocalLibraryWork(_ workID: SyncWorkID) async -> Bool {
        guard let library = deviceSyncRuntime?.library,
              let portable = portableDocumentRepository() else {
            return false
        }
        do {
            try await library.validateInstalledPackage(workID)
            let sourceURL = try await library.packageURL(workID)
            let document = try await portable.validatePortablePackage(at: sourceURL)
            let publication = await createPrivateLibraryWorkSerially(
                document,
                portableSourceURL: sourceURL,
                portableRepository: portable,
                activate: false
            )
            guard let publication else {
                print("[FUMINIWA] cloud-library action failed(duplicateInstall)")
                cloudLibraryActionMessage = "作品を複製できませんでした。"
                return false
            }
            schedulePrivateLibraryPublish(publication)
            return true
        } catch {
            presentCloudLibraryActionFailure(
                error,
                message: "作品を複製できませんでした。"
            )
            return false
        }
    }

    func presentCloudLibraryActionFailure(_ error: any Error, message: String) {
        DeviceSyncLog.event("action failed", error: error)
        cloudLibraryActionMessage = DeviceSyncLog.userFacingMessage(message, error: error)
    }
}
