import EditorKit
import SwiftUI

struct ContentView: View {
    @Environment(DocumentPanelPresenter.self) private var documentPanelPresenter
    @Environment(ExportPresenter.self) private var exportPresenter

    var body: some View {
        NovelWorkbenchView()
            .alert(
                "操作を完了できませんでした",
                isPresented: Binding(
                    get: { documentPanelPresenter.alertMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            documentPanelPresenter.alertMessage = nil
                        }
                    }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(documentPanelPresenter.alertMessage ?? "")
            }
            .overlay(alignment: .bottomTrailing) {
                if exportPresenter.state != .idle {
                    ExportStatusView(presenter: exportPresenter)
                        .padding(16)
                }
            }
    }
}

extension Notification.Name {
    static let toggleWritingInspector = Notification.Name("dev.serikayuzuki.fuminiwa.toggleWritingInspector")
    static let presentChapterMemo = Notification.Name("dev.serikayuzuki.fuminiwa.presentChapterMemo")
    static let presentAttachmentImporter = Notification.Name("dev.serikayuzuki.fuminiwa.presentAttachmentImporter")
}

#Preview {
    let appState = AppState(dependencies: AppDependencies())
    return ContentView()
        .environment(appState)
        .environment(EditorSettings())
        .environment(DocumentPanelPresenter(appState: appState))
        .environment(SnapshotMenuPresenter(appState: appState))
        .environment(ExportPresenter(appState: appState))
        .environment(EditorSearchSession())
        .environment(EditorCommandSession())
}
