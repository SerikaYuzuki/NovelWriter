import NovelThumbnail
import SwiftUI

public struct ThumbnailCropSheet: View {
    let data: Data
    let owner: ThumbnailOwner
    let onSave: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var crop = ThumbnailCrop()
    @State private var dragStart: ThumbnailCrop?
    @State private var zoomStart: Double?
    @State private var error: String?
    @State private var preview: CGImage?
    public init(data: Data, owner: ThumbnailOwner, onSave: @escaping (Data) -> Void) {
        self.data = data; self.owner = owner; self.onSave = onSave
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: Spacing.group) {
                Text("ドラッグで位置、ピンチまたはスライダーで大きさを調整します。")
                    .font(.callout)
                if let preview {
                    cropPreview(preview)
                } else {
                    ProgressView("画像を読み込み中…")
                }
                Slider(value: $crop.zoom, in: 1 ... 8).accessibilityLabel("画像の拡大率")
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .padding(Spacing.outer)
            .navigationTitle("画像を切り抜く")
            .task {
                let data = data
                do {
                    let image = try await Task.detached(priority: .userInitiated) { try ThumbnailEncoder.preview(data) }.value
                    guard !Task.isCancelled else { return }
                    preview = image
                } catch { self.error = error.localizedDescription }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("使用する") {
                        do { let encoded = try ThumbnailEncoder.encode(data, owner: owner, crop: crop); onSave(encoded); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(preview == nil)
                }
            }
        }
        #if os(macOS)
        .frame(width: 420, height: 560)
        #endif
    }

    private func cropPreview(_ image: CGImage) -> some View {
        let width: CGFloat = owner.kind == .work ? 200 : 280
        let height = width / owner.aspectRatio
        let base = max(width / CGFloat(image.width), height / CGFloat(image.height))
        let factor = base * crop.zoom
        let shape = RoundedRectangle(cornerRadius: owner.kind == .character ? width / 2 : owner.kind == .work ? Radius.cover : Radius.thumbnail)
        return Image(decorative: image, scale: 1).resizable()
            .frame(width: CGFloat(image.width) * factor, height: CGFloat(image.height) * factor)
            .offset(x: (0.5 - crop.centerX) * CGFloat(image.width) * factor, y: (0.5 - crop.centerY) * CGFloat(image.height) * factor)
            .frame(width: width + 32, height: height + 32).clipped()
            .overlay {
                Rectangle().fill(.black.opacity(0.55))
                    .mask {
                        Rectangle().overlay {
                            shape.frame(width: width, height: height).blendMode(.destinationOut)
                        }.compositingGroup()
                    }
                    .allowsHitTesting(false)
            }
            .overlay {
                shape.stroke(.white, lineWidth: 1.5).frame(width: width, height: height)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture().onChanged { value in
                let initial = dragStart ?? crop; dragStart = initial
                crop.centerX = initial.centerX - value.translation.width / (CGFloat(image.width) * factor)
                crop.centerY = initial.centerY - value.translation.height / (CGFloat(image.height) * factor)
                clamp(image, width: width, height: height, base: base)
            }.onEnded { _ in dragStart = nil })
            .simultaneousGesture(MagnifyGesture().onChanged { value in
                let initial = zoomStart ?? crop.zoom; zoomStart = initial
                crop.zoom = min(max(initial * value.magnification, 1), 8)
                clamp(image, width: width, height: height, base: base)
            }.onEnded { _ in zoomStart = nil })
            .onChange(of: crop.zoom) { _, _ in clamp(image, width: width, height: height, base: base) }
        #if os(macOS)
            .overlay { ThumbnailScrollZoom { delta in crop.zoom = min(max(crop.zoom * exp(delta), 1), 8) } }
        #endif
            .accessibilityLabel("切り抜き範囲")
    }

    private func clamp(_ image: CGImage, width: CGFloat, height: CGFloat, base: Double) {
        let halfX = width / (Double(image.width) * base * crop.zoom * 2)
        let halfY = height / (Double(image.height) * base * crop.zoom * 2)
        crop.centerX = min(max(crop.centerX, halfX), 1 - halfX)
        crop.centerY = min(max(crop.centerY, halfY), 1 - halfY)
    }
}
