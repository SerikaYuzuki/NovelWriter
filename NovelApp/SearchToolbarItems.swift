import SwiftUI

struct SearchToolbarItems: View {
    @Binding var query: String

    let didMissSearch: Bool
    let isChapterSelected: Bool
    let onQueryChanged: (String) -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        TextField("検索", text: $query)
            .textFieldStyle(.roundedBorder)
            .frame(width: 180)
            .onSubmit {
                onNext()
            }
            .onChange(of: query) { _, newQuery in
                onQueryChanged(newQuery)
            }

        Button {
            onPrevious()
        } label: {
            Label("前の検索結果", systemImage: "chevron.up")
        }
        .disabled(query.isEmpty || !isChapterSelected)

        Button {
            onNext()
        } label: {
            Label("次の検索結果", systemImage: "chevron.down")
        }
        .disabled(query.isEmpty || !isChapterSelected)

        if didMissSearch {
            Text("見つかりません")
                .foregroundStyle(.secondary)
        }
    }
}
