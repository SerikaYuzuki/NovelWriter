import AppKit
import EditorKit
import NovelCore
import NovelUI
import SwiftUI

struct WritingModeView: View {
    var body: some View {
        // Toolbar-1 以降、Outline は NavigationSplitView の content 列へ移した。
        // Toolbar-2 以降、上部 chrome は WorkbenchToolbarContent が所有する。
        EditorPaneView()
    }
}
