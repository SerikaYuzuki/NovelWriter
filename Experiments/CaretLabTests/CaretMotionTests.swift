import AppKit
@testable import FUMINIWACaretLab
import SwiftUI
import Testing

@MainActor
@Suite("IME caret experiment", .serialized)
struct CaretMotionTests {
    @Test("行内の短い移動だけを補間し、折返し・大移動・初回配置は即時にする")
    func movementPolicy() {
        let initial = NSRect(x: 20, y: 40, width: 2, height: 20)
        #expect(CaretMotionPolicy.shouldAnimate(
            from: initial, to: initial.offsetBy(dx: 20, dy: 0), requested: true
        ))
        #expect(!CaretMotionPolicy.shouldAnimate(
            from: initial, to: initial.offsetBy(dx: 20, dy: 24), requested: true
        ))
        #expect(!CaretMotionPolicy.shouldAnimate(
            from: initial, to: initial.offsetBy(dx: 200, dy: 0), requested: true
        ))
        #expect(!CaretMotionPolicy.shouldAnimate(from: nil, to: initial, requested: true))
        #expect(!CaretMotionPolicy.shouldAnimate(from: initial, to: initial, requested: false))
    }

    @Test("改行は離れた行末から次の行頭まで補間し、逆方向・複数行・高さ変更は即時にする")
    func newlineMovementPolicy() {
        let endOfLine = NSRect(x: 500, y: 40, width: 2, height: 24)
        let nextLine = NSRect(x: 20, y: 70, width: 2, height: 24)
        #expect(CaretMotionPolicy.shouldAnimate(
            from: endOfLine, to: nextLine, requested: true, afterNewline: true
        ))
        #expect(!CaretMotionPolicy.shouldAnimate(from: endOfLine, to: nextLine, requested: true))
        #expect(!CaretMotionPolicy.shouldAnimate(
            from: nextLine, to: endOfLine, requested: true, afterNewline: true
        ))
        #expect(!CaretMotionPolicy.shouldAnimate(
            from: endOfLine, to: nextLine.offsetBy(dx: 0, dy: 40), requested: true, afterNewline: true
        ))
        #expect(!CaretMotionPolicy.shouldAnimate(
            from: endOfLine, to: NSRect(x: 20, y: 70, width: 2, height: 36),
            requested: true, afterNewline: true
        ))
        #expect(!CaretMotionPolicy.shouldAnimate(
            from: endOfLine, to: nextLine, requested: false, afterNewline: true
        ))
        #expect(!CaretMotionPolicy.shouldAnimate(
            from: nil, to: nextLine, requested: true, afterNewline: true
        ))
    }

    @Test("通常入力とIME確定後の改行は字下げ位置へ動き、連続改行とUndo/Redoを保つ", arguments: [false, true])
    func newlineAfterTyping(afterComposition: Bool) async throws {
        let body = "少し長い文章の末尾から改行を試します。"
        let fixture = try await makeFixture(body: body)
        defer { fixture.window.close() }
        let editor = fixture.editor
        editor.setSelectedRange(NSRange(location: body.utf16.count, length: 0))
        editor.motionEnabled = true
        if afterComposition {
            editor.setMarkedText("へんかん", selectedRange: NSRange(location: 4, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
            editor.insertText("変換", replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(!editor.hasMarkedText())
        }
        let original = editor.string
        let undo = try #require(editor.undoManager)
        undo.removeAllActions()
        undo.groupsByEvent = false
        for index in 1 ... 2 {
            let previousFrame = try #require(editor.displayedCaretFrame)
            let previousAnimationCount = editor.animationCount
            undo.beginUndoGrouping()
            editor.insertNewline(nil)
            undo.endUndoGrouping()
            #expect(editor.string == original + String(repeating: "\n　", count: index))
            #expect(fixture.changes.values.last == editor.string)
            #expect(editor.selectedRange() == NSRange(location: editor.string.utf16.count, length: 0))
            #expect(editor.animationCount == previousAnimationCount + 1)
            #expect(editor.isMovementAnimating)
            let nextFrame = try #require(editor.displayedCaretFrame)
            #expect(nextFrame.minY > previousFrame.minY)
            let candidateRect = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
            editor.motionEnabled = false
            #expect(editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil) == candidateRect)
            editor.motionEnabled = true
        }
        undo.undo()
        #expect(editor.string == original + "\n　")
        undo.undo()
        #expect(editor.string == original)
        undo.redo()
        #expect(editor.string == original + "\n　")
        undo.redo()
        #expect(editor.string == original + "\n　\n　")
        #expect(editor.textLayoutManager != nil)
    }

    @Test("同じEditorKitを使い、IME未確定本文をモデルへ流さず縦線だけ動かす")
    func compositionAndCandidateCoordinates() async throws {
        let fixture = try await makeFixture()
        defer { fixture.window.close() }
        let editor = fixture.editor
        #expect(editor.textLayoutManager != nil)
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        editor.motionEnabled = true
        editor.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.setMarkedText("かきく", selectedRange: NSRange(location: 3, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        #expect(fixture.changes.values.isEmpty)
        #expect(editor.markedAnimationCount > 0)
        let selection = editor.selectedRange()
        let marked = editor.markedRange()
        let candidateRect = editor.firstRect(forCharacterRange: selection, actualRange: nil)
        #expect(editor.displayedCaretFrame != nil)
        editor.motionEnabled = false
        #expect(editor.displayedCaretFrame == nil)
        #expect(editor.hasMarkedText())
        #expect(editor.selectedRange() == selection)
        #expect(editor.markedRange() == marked)
        #expect(editor.firstRect(forCharacterRange: selection, actualRange: nil) == candidateRect)
        editor.motionEnabled = true
        #expect(editor.firstRect(forCharacterRange: selection, actualRange: nil) == candidateRect)
        editor.insertText("書き句", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!editor.hasMarkedText())
        #expect(editor.string == "本文書き句")
        #expect(fixture.changes.values.last == "本文書き句")
    }

    @Test("変換確定のUndo/Redo、範囲選択、保存境界、再有効化でも本文を変えない")
    func undoSelectionAndSaveBoundary() async throws {
        let fixture = try await makeFixture()
        defer { fixture.window.close() }
        let editor = fixture.editor
        let undo = try #require(editor.undoManager)
        editor.motionEnabled = true
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        editor.setMarkedText("へんかん", selectedRange: NSRange(location: 4, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.insertText("変換", replacementRange: NSRange(location: NSNotFound, length: 0))
        undo.endUndoGrouping()
        #expect(editor.string == "本文変換")
        undo.undo()
        #expect(editor.string == "本文")
        undo.redo()
        #expect(editor.string == "本文変換")
        editor.setSelectedRange(NSRange(location: 1, length: 2))
        editor.refreshCaret(animate: false)
        #expect(editor.displayedCaretFrame == nil)
        let selected = editor.selectedRange()
        let origin = editor.enclosingScrollView?.contentView.bounds.origin
        #expect(fixture.session.prepareForDocumentTransition())
        fixture.session.resumeAfterDocumentTransition()
        #expect(editor.selectedRange() == selected)
        #expect(editor.enclosingScrollView?.contentView.bounds.origin == origin)
        #expect(editor.string == "本文変換")
        editor.motionEnabled = false
        editor.motionEnabled = true
        #expect(editor.selectedRange() == selected)
        #expect(undo.canUndo)
    }

    @Test("改行・絵文字と変換取消を標準入力経路で扱う")
    func unicodeNewlineAndCancellation() async throws {
        let fixture = try await makeFixture()
        defer { fixture.window.close() }
        let editor = fixture.editor
        editor.motionEnabled = true
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        editor.insertText("👩‍👩‍👧‍👦", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.selectedRange().location == ("本文👩‍👩‍👧‍👦" as NSString).length)
        editor.insertNewline(nil)
        let committed = editor.string
        editor.setMarkedText("とりけし", selectedRange: NSRange(location: 4, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.insertText("", replacementRange: editor.markedRange())
        #expect(!editor.hasMarkedText())
        #expect(editor.string == committed)
        #expect(fixture.changes.values.last == committed)
        #expect(editor.textLayoutManager != nil)
    }

    @Test("スクロールとフォーカス喪失では追従を止め、標準の入力位置を維持する")
    func scrollAndFocusStopMovement() async throws {
        let body = (0 ..< 60).map { "\($0) 行の試し書きです。" }.joined(separator: "\n")
        let fixture = try await makeFixture(body: body)
        defer { fixture.window.close() }
        let editor = fixture.editor
        let location = (body as NSString).range(of: "20 行").location
        editor.setSelectedRange(NSRange(location: location, length: 0))
        editor.scrollRangeToVisible(editor.selectedRange())
        editor.motionEnabled = true
        editor.moveForward(nil)
        #expect(editor.isMovementAnimating)
        let selection = editor.selectedRange()
        let scroll = try #require(editor.enclosingScrollView)
        #expect(scroll.contentView.postsBoundsChangedNotifications)
        let previousOrigin = scroll.contentView.bounds.origin
        let previousScrollEvents = editor.observedScrollChangeCount
        scroll.contentView.scroll(to: previousOrigin.applying(
            CGAffineTransform(translationX: 0, y: 1)
        ))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(scroll.contentView.bounds.origin != previousOrigin)
        // AppKit coalesces bounds-change notifications until the next run-loop turn.
        try await Task.sleep(for: .milliseconds(5))
        #expect(editor.observedScrollChangeCount > previousScrollEvents)
        #expect(!editor.isMovementAnimating)
        #expect(editor.selectedRange() == selection)
        fixture.window.actsAsKeyWindow = false
        editor.refreshCaret(animate: false)
        #expect(editor.displayedCaretFrame == nil)
        fixture.window.actsAsKeyWindow = true
        editor.refreshCaret(animate: false)
        #expect(editor.displayedCaretFrame != nil)
        #expect(editor.selectedRange() == selection)
    }

    @MainActor
    private final class Changes {
        var values: [String] = []
    }

    private struct Fixture {
        let window: InputTestWindow
        let editor: AnimatedCaretTextView
        let session: EditorCommandSession
        let changes: Changes
    }

    /// A background test runner cannot acquire system keyboard focus reliably.
    /// Only focus is supplied here; text input, layout, marked text and Undo are real AppKit.
    private final class InputTestWindow: NSWindow {
        var actsAsKeyWindow = true
        override var isKeyWindow: Bool {
            actsAsKeyWindow
        }
    }

    private func makeFixture(body: String = "本文") async throws -> Fixture {
        let changes = Changes()
        let session = EditorCommandSession()
        let host = NSHostingView(rootView: EditorView(
            chapterKey: "test", initialText: body, commandSession: session
        ) { changes.values.append($0) })
        let window = InputTestWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 450),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let editor = try #require(descendants(host).compactMap { $0 as? AnimatedCaretTextView }.first)
        window.makeFirstResponder(editor)
        changes.values.removeAll()
        return Fixture(window: window, editor: editor, session: session, changes: changes)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
}
