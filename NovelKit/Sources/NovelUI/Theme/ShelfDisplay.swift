import SwiftUI

public enum ShelfDisplay: String, CaseIterable {
    case grid, list
}

public struct ShelfDisplayPicker: View {
    @Binding var selection: ShelfDisplay
    public init(selection: Binding<ShelfDisplay>) {
        _selection = selection
    }

    public var body: some View {
        Picker("作品の表示", selection: $selection) {
            Label("表紙", systemImage: "square.grid.2x2").tag(ShelfDisplay.grid)
            Label("一覧", systemImage: "list.bullet").tag(ShelfDisplay.list)
        }
        .pickerStyle(.segmented)
        .fixedSize()
    }
}
