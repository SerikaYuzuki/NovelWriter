import NovelThumbnail
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#endif

public struct ThumbnailEditor: View {
    let owner: ThumbnailOwner
    let data: Data?
    let title: String
    let color: Color?
    let save: (Data?) async -> Bool
    @State private var importing = false
    @State private var removing = false
    @State private var picked: PickedImage?
    @State private var error: String?
    @State private var saving = false
    #if os(iOS)
    @State private var photo: PhotosPickerItem?
    #endif

    public init(owner: ThumbnailOwner, data: Data?, title: String, color: Color? = nil,
                save: @escaping (Data?) async -> Bool) {
        self.owner = owner; self.data = data; self.title = title; self.color = color; self.save = save
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            if owner.kind != .worldNote || data != nil {
                ThumbnailImage(data: data, kind: owner.kind, title: title, size: owner.kind == .character ? 72 : 96, color: color)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(title)の画像")
                    .contextMenu { controls }
            }
            HStack {
                Menu(data == nil ? "画像を設定…" : "画像を変更…") { controls }
                    .accessibilityLabel(data == nil ? "\(title)の画像を設定" : "\(title)の画像を変更")
                if saving {
                    ProgressView().controlSize(.small)
                }
            }
            #if os(iOS)
            PhotosPicker("写真から選ぶ…", selection: $photo, matching: .images)
                .accessibilityLabel("\(title)の画像を写真から選ぶ")
                .onChange(of: photo) { _, value in
                    Task {
                        do {
                            guard let bytes = try await value?.loadTransferable(type: Data.self) else { return }
                            picked = PickedImage(data: bytes)
                        } catch { self.error = "写真を読み込めませんでした。" }
                        photo = nil
                    }
                }
            #endif
        }
        .disabled(saving)
        #if os(macOS)
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first, !saving else { return false }; read(url); return true
            }
        #endif
            .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
                switch result { case let .success(url): read(url); case let .failure(error): self.error = error.localizedDescription }
            }
            .sheet(item: $picked) { item in
                ThumbnailCropSheet(data: item.data, owner: owner) { bytes in persist(bytes) }
            }
            .confirmationDialog("\(title)の画像を削除しますか？", isPresented: $removing) {
                Button("削除", role: .destructive) { persist(nil) }
                Button("キャンセル", role: .cancel) {}
            } message: { Text("以前の画像は作品の履歴から復元できます。") }
            .alert("画像を変更できませんでした", isPresented: Binding(get: { error != nil }, set: {
                if !$0 {
                    error = nil
                }
            })) {
                Button("閉じる") { error = nil }
            } message: { Text(error ?? "") }
    }

    @ViewBuilder private var controls: some View {
        Button(data == nil ? "ファイルから画像を設定…" : "ファイルから画像を置換…") { importing = true }
        if data != nil {
            Button("画像を削除…", role: .destructive) { removing = true }
        }
    }

    private func read(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer {
            if access {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do { picked = try PickedImage(data: Data(contentsOf: url)) }
        catch { self.error = "画像を読み込めませんでした。別の画像を選んでください。" }
    }

    private func persist(_ data: Data?) {
        saving = true
        Task {
            if await !save(data) {
                error = "画像を保存できませんでした。作品を開き直してお試しください。"
            }
            saving = false
        }
    }
}

private struct PickedImage: Identifiable {
    let id = UUID()
    let data: Data
}
