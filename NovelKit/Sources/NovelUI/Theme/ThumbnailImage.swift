import CryptoKit
import ImageIO
import NovelThumbnail
import SwiftUI

@MainActor
private final class ThumbnailImageCache {
    static let shared = ThumbnailImageCache()
    let images = NSCache<NSString, CGImage>()
    init() {
        images.totalCostLimit = 12 * 1024 * 1024; images.countLimit = 100
    }

    func image(_ data: Data, edge: Int) -> CGImage? {
        let key = "\(SHA256.hash(data: data))-\(edge)" as NSString
        if let cached = images.object(forKey: key) {
            return cached
        }
        guard let image = try? ThumbnailEncoder.preview(data, maximumEdge: edge) else { return nil }
        images.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }
}

public struct ThumbnailImage: View {
    let data: Data?
    let kind: ThumbnailOwner.Kind
    let title: String
    let size: CGFloat
    let color: Color?
    @Environment(\.displayScale) private var scale
    public init(data: Data?, kind: ThumbnailOwner.Kind, title: String, size: CGFloat, color: Color? = nil) {
        self.data = data; self.kind = kind; self.title = title; self.size = size; self.color = color
    }

    public var body: some View {
        if kind == .work {
            content.clipShape(RoundedRectangle(cornerRadius: Radius.cover, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.cover).strokeBorder(FuminiwaColor.separator.color, lineWidth: 0.5))
                .coverShadow()
        } else if kind == .character {
            content.clipShape(Circle())
        } else {
            content.clipShape(RoundedRectangle(cornerRadius: Radius.thumbnail, style: .continuous))
        }
    }

    private var content: some View {
        ZStack {
            if let data, let image = ThumbnailImageCache.shared.image(data, edge: Int(size * (kind == .work ? 1.5 : 1) * scale)) {
                Image(decorative: image, scale: scale).resizable().scaledToFill()
            } else if kind == .work {
                FuminiwaColor.paper.color
                HStack(spacing: 0) { FuminiwaColor.accent.color.frame(width: size / 8); Spacer(minLength: 0) }
                Text(CoverInitial.character(in: title)).font(FuminiwaType.workTitle).minimumScaleFactor(0.5)
                    .foregroundStyle(FuminiwaColor.textPrimary.color)
            } else if kind == .character {
                color ?? FuminiwaColor.sunken.color
                Text(String(title.first ?? "人")).font(.headline).foregroundStyle(FuminiwaColor.textPrimary.color)
            } else {
                FuminiwaColor.accentMuted.color
                Image(systemName: "globe.asia.australia").foregroundStyle(FuminiwaColor.accent.color)
            }
        }
        .frame(width: size, height: kind == .work ? size * 1.5 : size).clipped()
    }
}

@MainActor
private final class ShelfThumbnailCache {
    static let shared = ShelfThumbnailCache()
    let bytes = NSCache<NSString, NSData>()
    init() {
        bytes.totalCostLimit = 2 * 1024 * 1024; bytes.countLimit = 24
    }
}

public struct LazyCoverThumbnail: View {
    let title: String
    let identity: String
    let size: CGFloat
    let load: @MainActor () async -> Data?
    @State private var bytes: Data?
    public init(title: String, identity: String, size: CGFloat = 32, load: @escaping @MainActor () async -> Data?) {
        self.title = title; self.identity = identity; self.size = size; self.load = load
    }

    public var body: some View {
        ThumbnailImage(data: bytes, kind: .work, title: title, size: size)
            .accessibilityHidden(true)
            .task(id: identity) {
                bytes = nil
                if let cached = ShelfThumbnailCache.shared.bytes.object(forKey: identity as NSString) {
                    bytes = cached as Data
                    return
                }
                let result = await load()
                guard !Task.isCancelled else { return }
                bytes = result
                if let result {
                    ShelfThumbnailCache.shared.bytes.setObject(result as NSData, forKey: identity as NSString, cost: result.count)
                }
            }
    }
}
