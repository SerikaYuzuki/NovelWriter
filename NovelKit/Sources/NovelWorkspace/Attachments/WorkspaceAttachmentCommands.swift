import Foundation
import NovelCore
import NovelSyncV2
import NovelThumbnail

/// Attachment capability of WorkspaceHost. Persistence and editor gates remain injected by the app.
@MainActor
public protocol WorkspaceAttachmentHost: WorkspaceHost {
    var workspaceAttachments: WorkspaceAttachmentSet { get }
    func installWorkspaceAttachments(_ replacement: WorkspaceAttachmentSet)
}

@MainActor
public struct WorkspaceAttachmentCommands {
    public typealias Boundary = @MainActor (@escaping @MainActor () async -> Bool) async -> Bool
    public typealias Checkpoint = @MainActor (NovelDocument, WorkspaceAttachmentSet) async -> Bool

    private let host: any WorkspaceAttachmentHost
    private let boundary: Boundary
    private let checkpoint: Checkpoint

    public init(host: any WorkspaceAttachmentHost, boundary: @escaping Boundary,
                checkpoint: @escaping Checkpoint) {
        self.host = host
        self.boundary = boundary
        self.checkpoint = checkpoint
    }

    public func add(_ bytes: Data, named name: String, style: WorkspaceAttachmentSet.NamingStyle,
                    context: WorkspaceOperationContext) async -> SyncAttachment? {
        var item: SyncAttachment?
        let succeeded = await boundary {
            guard permits(context) else { return false }
            let previous = host.workspaceAttachments
            let (candidate, added) = previous.adding(bytes, named: name, style: style)
            guard await persist(candidate, replacing: previous, context: context) else { return false }
            item = added
            return true
        }
        return succeeded ? item : nil
    }

    public func delete(named name: String, context: WorkspaceOperationContext) async -> Bool {
        await boundary {
            guard permits(context), host.workspaceAttachments[name] != nil else { return false }
            let previous = host.workspaceAttachments
            return await persist(previous.removing(named: name), replacing: previous, context: context)
        }
    }

    public func rename(_ name: String, to newName: String, style: WorkspaceAttachmentSet.NamingStyle,
                       context: WorkspaceOperationContext) async -> Bool {
        await boundary {
            guard permits(context) else { return false }
            let previous = host.workspaceAttachments
            guard let candidate = previous.renaming(name, to: newName, style: style), candidate != previous else { return false }
            return await persist(candidate, replacing: previous, context: context)
        }
    }

    public func setThumbnail(_ bytes: Data?, owner: ThumbnailOwner, context: WorkspaceOperationContext) async -> Bool {
        await boundary {
            guard permits(context), owner.exists(in: host.document) else { return false }
            let previous = host.workspaceAttachments
            let candidate = previous.settingThumbnail(bytes, owner: owner)
            guard await checkpoint(host.document, candidate), permits(context), owner.exists(in: host.document),
                  host.workspaceAttachments[owner.fileName] == previous[owner.fileName] else { return false }
            // Apply only this resource so concurrent owner removals are never resurrected.
            let live = host.workspaceAttachments.removing(named: owner.fileName)
            let records = live.records + candidate.records.filter { $0.fileName == owner.fileName }
            guard let replacement = WorkspaceAttachmentSet(records) else { return false }
            host.installWorkspaceAttachments(replacement)
            return true
        }
    }

    /// Synchronous owner + resource edit, before the host's existing save notification.
    public static func applyOwnerRemoval(_ replacement: NovelDocument, host: any WorkspaceAttachmentHost) {
        host.installWorkspaceAttachments(host.workspaceAttachments.removingOwners(from: host.document, to: replacement))
        host.document = replacement
    }

    private func persist(_ candidate: WorkspaceAttachmentSet, replacing previous: WorkspaceAttachmentSet,
                         context: WorkspaceOperationContext) async -> Bool {
        guard await checkpoint(host.document, candidate), permits(context), host.workspaceAttachments == previous else { return false }
        host.installWorkspaceAttachments(candidate)
        return true
    }

    private func permits(_ expected: WorkspaceOperationContext) -> Bool {
        let current = host.operationContext
        // Editing during checkpoint is allowed and is flushed by the host after the operation.
        return !Task.isCancelled && host.permitsLocalMutation && expected.session != nil
            && expected.workID == current.workID && expected.session == current.session && expected.account == current.account
    }
}
