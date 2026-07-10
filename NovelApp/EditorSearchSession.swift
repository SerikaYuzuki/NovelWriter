import AppKit
import EditorKit
import Foundation
import NovelCore
import Observation
import SwiftUI

/// 章内検索のウィンドウ単位の一時状態(docs/TOOLBAR.md Toolbar-2)。
///
/// `NovelDocument` や保存形式には含めない。検索結果の選択反映は
/// `selectionRequest` 経由で `EditorView` へ渡す。
@MainActor
@Observable
final class EditorSearchSession {
    var query = ""
    var didMissSearch = false
    /// `.searchable(isPresented:)` 用。執筆セクションでは既定で表示し、Cmd+F で再フォーカスする。
    var isSearchPresented = true

    private(set) var selectionRequest: EditorSelectionRequest?
    private var lastSearchChapterID: ChapterID?
    private var lastSearchQuery = ""
    private var lastSearchRange: NSRange?

    /// ツールバー検索欄へフォーカスを移す。既に表示中でも一度閉じて開き直す。
    func focusSearchField() {
        isSearchPresented = false
        Task { @MainActor in
            isSearchPresented = true
        }
    }

    func jump(direction: TextSearchDirection, in chapter: Chapter?) {
        guard let chapter, !query.isEmpty else { return }

        let startLocation: Int = if lastSearchChapterID == chapter.id,
                                    lastSearchQuery == query,
                                    let lastSearchRange
        {
            switch direction {
            case .forward:
                lastSearchRange.location + lastSearchRange.length
            case .backward:
                lastSearchRange.location
            }
        } else {
            switch direction {
            case .forward:
                0
            case .backward:
                (chapter.content as NSString).length
            }
        }

        guard let range = TextSearch.find(
            query: query,
            in: chapter.content,
            from: startLocation,
            direction: direction
        ) else {
            didMissSearch = true
            NSSound.beep()
            return
        }

        didMissSearch = false
        lastSearchChapterID = chapter.id
        lastSearchQuery = query
        lastSearchRange = range
        selectionRequest = EditorSelectionRequest(range: range)
    }

    func requestSelection(range: NSRange) {
        selectionRequest = EditorSelectionRequest(range: range)
    }

    func resetCursor() {
        didMissSearch = false
        lastSearchChapterID = nil
        lastSearchQuery = ""
        lastSearchRange = nil
        selectionRequest = nil
    }

    func handleChapterChange(_ newSelection: ChapterID?) {
        if lastSearchChapterID != newSelection {
            resetCursor()
        }
    }
}

/// Cmd+F のフォーカス分岐用(docs/TOOLBAR.md §6)。
enum WorkbenchSearchSurface: Equatable {
    case outline
    case editor
}

private struct WorkbenchSearchSurfaceKey: FocusedValueKey {
    typealias Value = WorkbenchSearchSurface
}

extension FocusedValues {
    var workbenchSearchSurface: WorkbenchSearchSurface? {
        get { self[WorkbenchSearchSurfaceKey.self] }
        set { self[WorkbenchSearchSurfaceKey.self] = newValue }
    }
}
