import SwiftUI

public extension View {
    /// macOS TextEditor lays out lines with the system UI font's metrics, which
    /// are shorter than Japanese glyphs: the first line's top is clipped and
    /// lines nearly touch. A Japanese font with a little leading fixes both.
    func japaneseTextEditorStyle() -> some View {
        #if os(macOS)
        font(.custom("Hiragino Sans", size: NSFont.systemFontSize))
            .lineSpacing(3)
            .contentMargins(.vertical, 6, for: .scrollContent)
        #else
        self
        #endif
    }
}
