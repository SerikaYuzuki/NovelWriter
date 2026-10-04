import SwiftUI

public struct ProofreadingChecklistView: View {
    @Binding private var selection: Set<String>
    public init(selection: Binding<Set<String>>) {
        _selection = selection
    }

    public var body: some View {
        ForEach(ProofreadingCheck.allCases) { item in
            Toggle(item.label, isOn: Binding(get: { selection.contains(item.id) }, set: { enabled in
                if enabled {
                    selection.insert(item.id)
                } else {
                    selection.remove(item.id)
                }
            }))
        }
    }
}
