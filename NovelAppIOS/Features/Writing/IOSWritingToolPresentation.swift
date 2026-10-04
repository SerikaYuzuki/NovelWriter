import SwiftUI

enum IOSWritingTool: String, Identifiable {
    case workSearch

    var id: Self {
        self
    }
}

struct IOSWritingToolPresentationModifier: ViewModifier {
    let store: IOSDocumentStore
    @Binding var destination: IOSWritingTool?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        if horizontalSizeClass == .regular {
            // The adaptive view owns presentation outside its split columns.
            // A destination registered in an inner column can prevent that
            // split from mounting again after a section switch.
            content.sheet(item: $destination) { tool in
                NavigationStack {
                    toolView(tool, onOpenEditor: { destination = nil })
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("閉じる") { destination = nil }
                            }
                        }
                }
            }
        } else {
            content.navigationDestination(item: $destination) { tool in
                toolView(tool)
            }
        }
    }

    @ViewBuilder
    private func toolView(_ tool: IOSWritingTool, onOpenEditor: (() -> Void)? = nil) -> some View {
        switch tool {
        case .workSearch: IOSWorkSearchView(store: store, onOpenEditor: onOpenEditor)
        }
    }
}
