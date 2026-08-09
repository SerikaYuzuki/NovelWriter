import SwiftUI
import UniformTypeIdentifiers

struct IOSRootView: View {
    @Bindable var store: IOSDocumentStore

    var body: some View {
        Group {
            switch store.startupState {
            case .loading:
                ProgressView("作品を読み込んでいます…")
            case .ready:
                IOSWorkbenchView(store: store)
            case let .recovery(message):
                IOSRecoveryView(store: store, message: message)
            }
        }
        .disabled(store.isDocumentTransitionInProgress)
        .overlay {
            if store.isDocumentTransitionInProgress {
                ZStack {
                    Color.black.opacity(0.08).ignoresSafeArea()
                    ProgressView("作品を準備しています…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .fileImporter(
            isPresented: $store.isImporterPresented,
            allowedContentTypes: [.fuminiwaNovelPackage],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                Task {
                    await store.importPackage(from: url)
                }
            case let .failure(error):
                store.operationErrorMessage = "作品を選択できませんでした。\n\(error.localizedDescription)"
            }
        }
        .alert(item: $store.promptCopyNotice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert("作品を操作できませんでした", isPresented: operationErrorIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.operationErrorMessage ?? "不明なエラーです。")
        }
        .sheet(isPresented: exportIsPresented) {
            if let url = store.pendingExportURL {
                IOSShareSheet(items: [url])
                    .ignoresSafeArea()
            }
        }
    }

    private var operationErrorIsPresented: Binding<Bool> {
        Binding(
            get: { store.operationErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    store.operationErrorMessage = nil
                }
            }
        )
    }

    private var exportIsPresented: Binding<Bool> {
        Binding(
            get: { store.pendingExportURL != nil },
            set: { isPresented in
                if !isPresented {
                    store.dismissExport()
                }
            }
        )
    }
}

private struct IOSRecoveryView: View {
    let store: IOSDocumentStore
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("作品を開けませんでした", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("別の作品を取り込む") {
                store.isImporterPresented = true
            }
            .buttonStyle(.borderedProminent)

            Button("新規作品を作る") {
                Task {
                    await store.makeNewDocument()
                }
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }
}

import UIKit

private struct IOSShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context _: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_: UIActivityViewController, context _: Context) {}
}
