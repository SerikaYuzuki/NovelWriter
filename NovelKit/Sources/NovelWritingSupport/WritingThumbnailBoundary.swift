import NovelCore
import NovelThumbnail

public enum WritingThumbnailBoundary {
    /// Write-back replaces the visible attachment array, but cannot address private images.
    /// Only an owner actually removed by this edit loses its image; pre-existing orphans survive.
    public static func merging(_ edited: [WritingAttachment], with original: [WritingAttachment],
                               from old: NovelDocument, to new: NovelDocument) throws -> [WritingAttachment] {
        let protected = original.filter { ThumbnailOwner.isReserved($0.fileName) }
        let protectedIDs = Set(protected.map(\.id))
        guard edited.allSatisfy({ !ThumbnailOwner.isReserved($0.fileName) && !protectedIDs.contains($0.id) }) else {
            throw WritingError.outsideGrant
        }
        let removed = ThumbnailOwner.removedNames(from: old, to: new)
        return edited + protected.filter { !removed.contains($0.fileName) }
    }
}
