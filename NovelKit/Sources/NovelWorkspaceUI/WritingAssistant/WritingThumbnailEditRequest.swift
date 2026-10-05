import Foundation
import NovelThumbnail
import NovelWritingSupport

/// Validated image mutation passed to the platform adapter. MCP parsing stays in the app.
public struct WritingThumbnailEditRequest: Sendable {
    public let edit: WritingEdit
    public let owner: ThumbnailOwner
    public let image: Data?

    public init(edit: WritingEdit, owner: ThumbnailOwner, image: Data?) {
        self.edit = edit; self.owner = owner; self.image = image
    }
}
