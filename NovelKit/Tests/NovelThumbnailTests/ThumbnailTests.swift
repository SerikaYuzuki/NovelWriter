import CoreGraphics
import Foundation
import ImageIO
import NovelCore
import NovelThumbnail
import Testing
import UniformTypeIdentifiers

@Suite("Thumbnail contract")
struct ThumbnailTests {
    @Test(arguments: ThumbnailOwner.Kind.allCases)
    func reservedNameRoundTrip(_ kind: ThumbnailOwner.Kind) throws {
        let id = try #require(UUID(uuidString: "ABCD1234-1111-2222-3333-123456789ABC"))
        let owner = ThumbnailOwner(kind, id)
        #expect(owner.fileName == "fuminiwa-thumbnail-v1-\(kind.rawValue)-abcd1234-1111-2222-3333-123456789abc.jpg")
        #expect(ThumbnailOwner(fileName: owner.fileName) == owner)
        #expect(ThumbnailOwner(fileName: owner.fileName.uppercased()) == nil)
        #expect(ThumbnailOwner.isReserved(owner.fileName.uppercased()))
        #expect(ThumbnailOwner(fileName: owner.fileName + ".bak") == nil)
        #expect(ThumbnailOwner(fileName: owner.fileName.replacingOccurrences(of: "v1", with: "v2")) == nil)
        #expect(ThumbnailOwner(fileName: "fuminiwa-thumbnail-v1-episode-\(id.uuidString.lowercased()).jpg") == nil)
    }

    @Test(arguments: ThumbnailOwner.Kind.allCases)
    func reencodingCropsBoundsAndStripsMetadata(_ kind: ThumbnailOwner.Kind) throws {
        let source = try SyntheticThumbnailImage.data(width: 2400, height: 1600, orientation: 6)
        let sourceReader = try #require(CGImageSourceCreateWithData(source as CFData, nil))
        let sourceProperties = try #require(CGImageSourceCopyPropertiesAtIndex(sourceReader, 0, nil) as? [CFString: Any])
        #expect(sourceProperties[kCGImagePropertyGPSDictionary] != nil)
        let owner = ThumbnailOwner(kind, UUID())
        let data = try ThumbnailEncoder.encode(source, owner: owner)
        #expect(data.count <= 200 * 1024)
        #expect(!data.contains(Data("SYNTHETIC-PRIVATE-METADATA".utf8)))
        let reader = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetType(reader) as String? == UTType.jpeg.identifier)
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(reader, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(properties[kCGImagePropertyExifDictionary] == nil)
        #expect(properties[kCGImagePropertyOrientation] == nil)
        let image = try #require(CGImageSourceCreateImageAtIndex(reader, 0, nil))
        #expect(max(image.width, image.height) <= owner.maximumEdge)
        #expect(abs(Double(image.width) / Double(image.height) - owner.aspectRatio) < 0.002)
        #expect(image.colorSpace?.name == CGColorSpace.sRGB)
    }

    @Test func orientationPanZoomAndSmallImages() throws {
        let source = try SyntheticThumbnailImage.data(width: 800, height: 400, orientation: 6)
        let oriented = try ThumbnailEncoder.preview(source)
        #expect(oriented.width == 400)
        #expect(oriented.height == 800)
        let owner = ThumbnailOwner(.character, UUID())
        let centered = try ThumbnailEncoder.encode(source, owner: owner)
        let moved = try ThumbnailEncoder.encode(source, owner: owner, crop: .init(centerX: 0.25, centerY: 0.25, zoom: 2))
        #expect(centered != moved)
        let small = try ThumbnailEncoder.preview(moved)
        #expect(small.width == 200)
        #expect(small.height == 200)
        #expect(throws: ThumbnailError.self) { try ThumbnailEncoder.encode(Data([1, 2, 3]), owner: owner) }
    }

    @Test func ownershipOnlyRemovesOwnersDeletedByThisEdit() {
        let character = Character(name: "合成人物")
        let note = WorldNote(title: "合成ノート", content: "テスト")
        let old = NovelDocument(title: "合成作品", chapters: [], characters: [character], worldNotes: [note])
        var new = old
        new.characters = []
        new.worldNotes = []
        let orphan = ThumbnailOwner(.character, UUID())
        let removed = ThumbnailOwner.removedNames(from: old, to: new)
        #expect(removed == [ThumbnailOwner(.character, character.id.rawValue).fileName, ThumbnailOwner(.worldNote, note.id.rawValue).fileName])
        #expect(!removed.contains(orphan.fileName))
        #expect(ThumbnailOwner(.work, old.id).exists(in: new))
        #expect(!orphan.exists(in: old))
    }
}
