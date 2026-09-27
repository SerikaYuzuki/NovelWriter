import AppKit
import SwiftUI

/// Keeps resizing separate from the editor's native navigation columns.
struct ResizableAssistantLayout<Content: View, Panel: View>: View {
    let isPresented: Bool
    @ViewBuilder let content: () -> Content
    @ViewBuilder let panel: () -> Panel
    @AppStorage private var preferredWidth: Double
    @State private var dragStartWidth: CGFloat?
    @State private var isHoveringDivider = false

    init(isPresented: Bool, defaults: UserDefaults, @ViewBuilder content: @escaping () -> Content,
         @ViewBuilder panel: @escaping () -> Panel) {
        self.isPresented = isPresented
        self.content = content
        self.panel = panel
        _preferredWidth = AppStorage(wrappedValue: 360, "fuminiwa.assistant.panelWidth", store: defaults)
    }

    var body: some View {
        GeometryReader { geometry in
            let maximum = max(300, min(720, geometry.size.width * 0.45))
            let width = min(max(300, preferredWidth), maximum)
            HStack(spacing: 0) {
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if isPresented {
                    resizeDivider(width: width, maximum: maximum)
                    panel()
                        .frame(width: width)
                        .background(.thinMaterial)
                        .accessibilityIdentifier("workbench.assistant.right")
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
    }

    private func resizeDivider(width: CGFloat, maximum: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { hovering in
                guard hovering != isHoveringDivider else { return }
                isHoveringDivider = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if dragStartWidth == nil {
                        dragStartWidth = width
                    }
                    preferredWidth = min(max(300, (dragStartWidth ?? width) - value.translation.width), maximum)
                }
                .onEnded { _ in dragStartWidth = nil })
            .onDisappear {
                dragStartWidth = nil
                if isHoveringDivider {
                    NSCursor.pop()
                    isHoveringDivider = false
                }
            }
            .accessibilityElement()
            .accessibilityLabel("AI支援パネルの幅")
            .accessibilityValue("\(Int(width))ポイント")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: preferredWidth = min(width + 24, maximum)
                case .decrement: preferredWidth = max(width - 24, 300)
                @unknown default: break
                }
            }
            .accessibilityIdentifier("workbench.assistant.resize")
            .help("左右にドラッグしてAI支援の幅を変更")
    }
}
