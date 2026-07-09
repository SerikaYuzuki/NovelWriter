import EditorKit
import SwiftUI

struct ContentView: View {
    @State private var searchSelectionRequest: EditorSelectionRequest?

    var body: some View {
        NovelWorkbenchView(
            searchSelectionRequest: $searchSelectionRequest
        )
    }
}

extension Notification.Name {
    static let toggleWritingInspector = Notification.Name("dev.serikayuzuki.NovelWriter.toggleWritingInspector")
}

#Preview {
    ContentView()
        .environment(AppState(dependencies: AppDependencies()))
        .environment(EditorSettings())
}
