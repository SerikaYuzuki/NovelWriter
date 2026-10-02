#if os(macOS)
import CoreFoundation
import CryptoKit
import Foundation
import ImageIO
import NovelCore
import NovelThumbnail
import NovelWritingSupport
import UniformTypeIdentifiers

/// Only dedicated MCP tools create these edits; ordinary WritingEdit validation stays unchanged.
struct WritingMCPThumbnailRequest {
    let edit: WritingEdit
    let owner: ThumbnailOwner
    let image: Data?

    static func owner(_ target: [String: Any]) throws -> ThumbnailOwner {
        guard let kind = (target["kind"] as? String).flatMap(ThumbnailOwner.Kind.init(rawValue:)),
              let id = (target["id"] as? String).flatMap(UUID.init(uuidString:)) else { throw WritingError.invalidEdit }
        return ThumbnailOwner(kind, id)
    }

    static func path(_ owner: ThumbnailOwner) -> [String] {
        let group = switch owner.kind {
        case .work: "work"
        case .character: "characters"
        case .worldNote: "worldNotes"
        }
        return ["thumbnails", group, owner.id.uuidString.lowercased()]
    }

    static func journalOwner(_ edit: WritingEdit) throws -> ThumbnailOwner {
        guard edit.changes.count == 1, let path = edit.changes.first?.path, path.count == 3,
              path[0] == "thumbnails", let id = UUID(uuidString: path[2]) else { throw WritingError.invalidEdit }
        let kind: ThumbnailOwner.Kind
        switch path[1] {
        case "work": kind = .work
        case "characters": kind = .character
        case "worldNotes": kind = .worldNote
        default: throw WritingError.invalidEdit
        }
        let owner = ThumbnailOwner(kind, id)
        guard Self.path(owner) == path else { throw WritingError.invalidEdit }
        return owner
    }

    static func make(_ arguments: [String: Any], capture: WritingCapture,
                     removing: Bool) throws -> (Self, WritingGrant) {
        guard let id = (arguments["requestId"] as? String).flatMap(UUID.init(uuidString:)),
              let target = arguments["target"] as? [String: Any],
              let scope = arguments["scope"] else { throw WritingError.invalidEdit }
        let owner = try owner(target)
        guard owner.exists(in: capture.document) else { throw WritingError.changedTarget }
        let grant = try JSONDecoder().decode(WritingGrant.self, from: JSONSerialization.data(withJSONObject: scope))
        guard grant.permits(path(owner)), !grant.appendOnly else { throw WritingError.outsideGrant }
        let crop = try crop(arguments["crop"])
        let source = removing ? nil : try WritingMCPThumbnailImage.decode(arguments["image"])
        let descriptor: WritingValue = .object([
            "operation": .string(removing ? "remove" : "set"),
            "sourceDigest": source.map { .string(digest($0)) } ?? .null,
            "crop": .object([
                "centerX": .number(crop.centerX),
                "centerY": .number(crop.centerY),
                "zoom": .number(crop.zoom)
            ])
        ])
        let edit = WritingEdit(id: id, workId: capture.workId, documentId: capture.document.id,
                               changes: [.init(path: path(owner), before: nil, after: descriptor)])
        let image = try source.map { try ThumbnailEncoder.encode($0, owner: owner, crop: crop) }
        return (Self(edit: edit, owner: owner, image: image), grant)
    }

    private static func crop(_ value: Any?) throws -> ThumbnailCrop {
        guard let value else { return .init() }
        guard let object = value as? [String: Any], Set(object.keys).isSubset(of: ["centerX", "centerY", "zoom"]) else {
            throw WritingError.invalidEdit
        }
        func number(_ key: String, default fallback: Double, range: ClosedRange<Double>) throws -> Double {
            guard let value = object[key] else { return fallback }
            guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, range.contains(value.doubleValue) else { throw WritingError.invalidEdit }
            return value.doubleValue
        }
        return try ThumbnailCrop(centerX: number("centerX", default: 0.5, range: 0 ... 1),
                                 centerY: number("centerY", default: 0.5, range: 0 ... 1),
                                 zoom: number("zoom", default: 1, range: 1 ... 8))
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum WritingMCPThumbnailImage {
    static let maximumSourceBytes = 8 * 1024 * 1024
    static let maximumSourceEdge = 8192
    static let maximumSourcePixels = 32_000_000

    static func decode(_ value: Any?) throws -> Data {
        guard let text = value as? String, text.utf8.count <= ((maximumSourceBytes + 2) / 3) * 4,
              let data = Data(base64Encoded: text), !data.isEmpty,
              data.count <= maximumSourceBytes else { throw WritingError.invalidEdit }
        try validate(data)
        return data
    }

    static func validate(_ data: Data, jpegOnly: Bool = false) throws {
        guard data.count <= maximumSourceBytes,
              let source = CGImageSourceCreateWithData(
                  data as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              CGImageSourceGetCount(source) == 1, CGImageSourceGetStatus(source) == .statusComplete,
              let type = CGImageSourceGetType(source) as String?,
              [UTType.png.identifier, UTType.jpeg.identifier, UTType.heic.identifier, UTType.webP.identifier]
              .contains(type),
              !jpegOnly || type == UTType.jpeg.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              (1 ... maximumSourceEdge).contains(width.intValue), (1 ... maximumSourceEdge).contains(height.intValue),
              width.intValue * height.intValue <= maximumSourcePixels else { throw WritingError.invalidEdit }
    }
}
#endif
