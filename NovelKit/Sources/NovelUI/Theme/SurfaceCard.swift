import SwiftUI

private struct SurfaceCard: ViewModifier {
    let selected: Bool
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .padding(Spacing.medium)
            .background(hovered ? FuminiwaColor.elevatedSurface.color : FuminiwaColor.surface.color,
                        in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(selected ? FuminiwaColor.accent.color : FuminiwaColor.separator.color,
                                  lineWidth: selected ? 1.5 : 0.5)
            }
        #if os(macOS)
            .onHover { hovered = $0 }
        #endif
    }
}

public extension View {
    func surfaceCard(selected: Bool = false) -> some View {
        modifier(SurfaceCard(selected: selected))
    }
}
