import EditorKit
import SwiftUI

struct ContentView: View {
    @Environment(DocumentPanelPresenter.self) private var documentPanelPresenter
    @State private var searchSelectionRequest: EditorSelectionRequest?

    var body: some View {
        NovelWorkbenchView(
            searchSelectionRequest: $searchSelectionRequest
        )
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
    }
}

extension Notification.Name {
    static let toggleWritingInspector = Notification.Name("dev.serikayuzuki.NovelWriter.toggleWritingInspector")
}

#Preview {
    let appState = AppState(dependencies: AppDependencies())
    return ContentView()
        .environment(appState)
        .environment(EditorSettings())
        .environment(DocumentPanelPresenter(appState: appState))
}
