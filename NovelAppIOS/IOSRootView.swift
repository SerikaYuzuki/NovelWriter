import SwiftUI
import UniformTypeIdentifiers

struct IOSRootView: View {
    @Bindable var store: IOSDocumentStore
    @State private var workspaceNavigation = IOSWorkspaceNavigationCoordinator()

    var body: some View {
        Group {
            switch store.startupState {
            case .loading:
                ProgressView("作品を読み込んでいます…")
            case .library, .ready:
                IOSWorkbenchView(
                    store: store,
                    navigation: workspaceNavigation
                )
            case let .recovery(message):
                IOSRecoveryView(
                    store: store,
                    message: message,
                    permitsDocumentRecovery: !store.deviceSyncStartupFailedSafely,
                    makeNewDocument: makeNewDocumentFromRecovery
                )
            }
        }
        .disabled(store.isDocumentTransitionInProgress)
        .overlay {
            if store.isDocumentTransitionInProgress {
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .ignoresSafeArea()
                    ProgressView("作品を準備しています…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
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
                guard !store.deviceSyncStartupFailedSafely else { return }
                guard let url = urls.first else { return }
                Task {
                    guard synchronizeActiveEditorBeforeDocumentChange(),
                          await store.importPackage(from: url) else { return }
                    showCurrentProjectHome()
                }
            case let .failure(error):
                store.operationErrorMessage = "作品を選択できませんでした。\n\(error.localizedDescription)"
            }
        }
        .onOpenURL { url in
            guard !store.deviceSyncStartupFailedSafely else { return }
            Task {
                guard synchronizeActiveEditorBeforeDocumentChange(),
                      await store.handleExternalPackageURL(url) else { return }
                showCurrentProjectHome()
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

    private func synchronizeActiveEditorBeforeDocumentChange() -> Bool {
        guard let departure = workspaceNavigation.activeEditorDeparture else { return true }
        return IOSWorkspaceEditorSynchronizer.synchronize(
            store: store,
            departure: departure
        )
    }

    private func showCurrentProjectHome() {
        guard let session = store.currentDocumentSessionToken else { return }
        workspaceNavigation.showProjectHome(for: session)
    }

    private func makeNewDocumentFromRecovery() {
        Task {
            guard await store.makeNewDocument() else { return }
            showCurrentProjectHome()
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
    let permitsDocumentRecovery: Bool
    let makeNewDocument: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("作品を開けませんでした", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            if permitsDocumentRecovery {
                Button("別の作品を取り込む") {
                    store.isImporterPresented = true
                }
                .buttonStyle(.borderedProminent)

                Button("新規作品を作る") {
                    makeNewDocument()
                }
                .buttonStyle(.bordered)
            }
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
