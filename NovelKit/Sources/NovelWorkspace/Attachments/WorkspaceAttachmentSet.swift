import Foundation
import NovelCore
import NovelSyncV2
import NovelThumbnail

/// Load order is retained; additions append, rename keeps its slot, thumbnail replacement appends.
/// Both apps already display this order. Dictionary enumeration never defines it.
public struct WorkspaceAttachmentSet: Equatable, Sendable {
    public enum NamingStyle: Sendable {
        case parentheses, hyphen
    }

    public private(set) var records: [SyncAttachment] = []

    public init() {}

    /// Reject invalid input rather than silently dropping resources.
    public init?(_ records: [SyncAttachment]) {
        var names = Set<String>(), ids = Set<UUID>()
        guard records.allSatisfy({ !$0.fileName.isEmpty && names.insert($0.fileName).inserted
                && ids.insert($0.attachmentId).inserted }) else { return nil }
        self.records = records
    }

    public var attachments: [Attachment] {
        records.map { Attachment(fileName: $0.fileName, byteCount: Int64($0.byteCount)) }
    }

    public subscript(fileName: String) -> SyncAttachment? {
        records.first { $0.fileName == fileName }
    }

    public func uniqueName(_ original: String, style: NamingStyle) -> String {
        guard self[original] != nil else { return original }
        let url = URL(fileURLWithPath: original)
        let stem = url.deletingPathExtension().lastPathComponent
        let suffix = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"
        var index = 2
        while true {
            let name = style == .parentheses ? "\(stem) (\(index))\(suffix)" : "\(stem)-\(index)\(suffix)"
            if self[name] == nil {
                return name
            }
            index += 1
        }
    }

    public func adding(_ bytes: Data, named sourceName: String, style: NamingStyle) -> (Self, SyncAttachment) {
        let source = sourceName.isEmpty ? "資料" : sourceName
        let original = ThumbnailOwner.isReserved(source) ? "資料-" + source : source
        let item = SyncAttachment(attachmentId: UUID(), fileName: uniqueName(original, style: style), bytes: bytes)
        var result = self
        result.records.append(item)
        return (result, item)
    }

    public func removing(named name: String) -> Self {
        var result = self
        result.records.removeAll { $0.fileName == name }
        return result
    }

    /// Reserved resources cannot be renamed through ordinary attachment commands.
    public func renaming(_ name: String, to newName: String, style: NamingStyle) -> Self? {
        guard !newName.isEmpty, !ThumbnailOwner.isReserved(name), !ThumbnailOwner.isReserved(newName),
              let index = records.firstIndex(where: { $0.fileName == name }) else { return nil }
        let item = records[index]
        let target = removing(named: name).uniqueName(newName, style: style)
        var result = self
        result.records[index] = SyncAttachment(attachmentId: item.attachmentId, fileName: target, bytes: item.bytes)
        return result
    }

    public func settingThumbnail(_ bytes: Data?, owner: ThumbnailOwner) -> Self {
        var result = removing(named: owner.fileName)
        if let bytes {
            result.records.append(SyncAttachment(attachmentId: UUID(), fileName: owner.fileName, bytes: bytes))
        }
        return result
    }

    public func removingOwners(from old: NovelDocument, to new: NovelDocument) -> Self {
        let names = ThumbnailOwner.removedNames(from: old, to: new)
        var result = self
        result.records.removeAll { names.contains($0.fileName) }
        return result
    }
}
