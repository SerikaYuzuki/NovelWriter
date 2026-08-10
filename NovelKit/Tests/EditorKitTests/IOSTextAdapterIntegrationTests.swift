#if canImport(UIKit) && !canImport(AppKit)
@testable import EditorKit
import Testing
import UIKit

@MainActor
@Suite(.serialized)
struct IOSTextAdapterIntegrationTests {
    final class Changes {
        var received: [String] = []
        var contextMenuSnapshots: [EditorSelectionContextMenuSnapshot] = []
    }

    struct Harness {
        let textView: IOSTextView
        let coordinator: IOSTextAdapter.Coordinator
        let changes: Changes
        let undoManager: UndoManager
        let window: UIWindow
    }

    func makeHarness(initialText: String) -> Harness {
        let textView = IOSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.text = initialText
        textView.typingAttributes = [.font: UIFont.systemFont(ofSize: 16)]

        let changes = Changes()
        let coordinator = IOSTextAdapter.Coordinator(
            onTextChange: { changes.received.append($0) }
        )
        coordinator.textView = textView
        textView.delegate = coordinator
        textView.editorCoordinator = coordinator
        coordinator.lastNotifiedCommittedText = initialText

        let viewController = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 932))
        window.rootViewController = viewController
        textView.frame = viewController.view.bounds
        viewController.view.addSubview(textView)
        window.makeKeyAndVisible()
        _ = textView.becomeFirstResponder()
        guard let undoManager = textView.undoManager else {
            fatalError("windowへ接続したUITextViewにnative UndoManagerがありません")
        }
        undoManager.removeAllActions()
        return Harness(
            textView: textView,
            coordinator: coordinator,
            changes: changes,
            undoManager: undoManager,
            window: window
        )
    }

    func advanceMainRunLoop() async {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform {
                continuation.resume()
            }
        }
    }

    @Test("iOS本文エディタはTextKit 2で生成される")
    func textViewUsesTextKit2() {
        let harness = makeHarness(initialText: "本文")

        #expect(harness.textView.textLayoutManager != nil)
    }

    @Test("iOS 26以降のmulti-range入力delegateを実装する")
    func respondsToMultiRangeInputDelegate() {
        let harness = makeHarness(initialText: "本文")

        #expect(
            harness.coordinator.responds(
                to: NSSelectorFromString("textView:shouldChangeTextInRanges:replacementText:")
            )
        )
    }

    @available(iOS 26.0, *)
    @Test("multi-range入力経路でも改行字下げと鉤括弧へ介入する")
    func multiRangeInputUsesCurrentIndentRules() {
        let harness = makeHarness(initialText: "本文")
        let textView = harness.textView
        textView.selectedRange = NSRange(location: 2, length: 0)

        let newlineHandledBySystem = harness.coordinator.textView(
            textView,
            shouldChangeTextInRanges: [NSValue(range: textView.selectedRange)],
            replacementText: "\n"
        )
        #expect(!newlineHandledBySystem)
        #expect(textView.text == "本文\n　")

        let bracketHandledBySystem = harness.coordinator.textView(
            textView,
            shouldChangeTextInRanges: [NSValue(range: textView.selectedRange)],
            replacementText: "「」"
        )
        #expect(!bracketHandledBySystem)
        #expect(textView.text == "本文\n「」")
        #expect(textView.selectedRange == NSRange(location: 4, length: 0))
    }

    @Test("Enterは常時改行と全角スペースを挿入し、キャレットを末尾へ置く")
    func newlineUsesCurrentIndentRules() {
        let harness = makeHarness(initialText: "本文\n　　")
        let textView = harness.textView
        textView.selectedRange = NSRange(location: (textView.text as NSString).length, length: 0)

        let shouldApplySystemChange = harness.coordinator.textView(
            textView,
            shouldChangeTextIn: textView.selectedRange,
            replacementText: "\n"
        )

        #expect(!shouldApplySystemChange)
        #expect(textView.text == "本文\n　　\n　")
        #expect(textView.selectedRange == NSRange(location: (textView.text as NSString).length, length: 0))
        #expect(harness.changes.received.last == textView.text)

        #expect(harness.undoManager.canUndo)
        harness.undoManager.undo()
        #expect(textView.text == "本文\n　　")
        #expect(harness.changes.received.last == "本文\n　　")

        #expect(harness.undoManager.canRedo)
        harness.undoManager.redo()
        #expect(textView.text == "本文\n　　\n　")
        #expect(harness.changes.received.last == "本文\n　　\n　")
    }

    @Test("開閉鉤括弧が別入力でも字下げを消し、キャレットを空ペア内へ置く")
    func separateBracketInputUsesD055Rules() {
        let harness = makeHarness(initialText: "　")
        let textView = harness.textView
        textView.selectedRange = NSRange(location: 1, length: 0)

        let openingHandledBySystem = harness.coordinator.textView(
            textView,
            shouldChangeTextIn: textView.selectedRange,
            replacementText: "「"
        )
        let closingHandledBySystem = harness.coordinator.textView(
            textView,
            shouldChangeTextIn: textView.selectedRange,
            replacementText: "」"
        )

        #expect(!openingHandledBySystem)
        #expect(!closingHandledBySystem)
        #expect(textView.text == "「」")
        #expect(textView.selectedRange == NSRange(location: 1, length: 0))

        harness.undoManager.undo()
        #expect(textView.text == "「")
        harness.undoManager.undo()
        #expect(textView.text == "　")

        harness.undoManager.redo()
        #expect(textView.text == "「")
        harness.undoManager.redo()
        #expect(textView.text == "「」")
        #expect(textView.selectedRange == NSRange(location: 1, length: 0))
    }

    @Test("文中へ一括入力した括弧ペアはキャレットをペア内へ置く")
    func bracketPairPlacesCaretInsideMidSentence() {
        let harness = makeHarness(initialText: "彼はと言った")
        let textView = harness.textView
        textView.selectedRange = NSRange(location: 2, length: 0)

        let shouldApplySystemChange = harness.coordinator.textView(
            textView,
            shouldChangeTextIn: textView.selectedRange,
            replacementText: "『』"
        )

        #expect(!shouldApplySystemChange)
        #expect(textView.text == "彼は『』と言った")
        #expect(textView.selectedRange == NSRange(location: 3, length: 0))
    }

    @Test("絵文字を含む文中でもUTF-16位置で括弧ペア内へキャレットを置く")
    func bracketPairUsesUTF16Offsets() {
        let harness = makeHarness(initialText: "前😀後")
        let textView = harness.textView
        let insertionLocation = ("前😀" as NSString).length
        textView.selectedRange = NSRange(location: insertionLocation, length: 0)

        let shouldApplySystemChange = harness.coordinator.textView(
            textView,
            shouldChangeTextIn: textView.selectedRange,
            replacementText: "「」"
        )

        #expect(!shouldApplySystemChange)
        #expect(textView.text == "前😀「」後")
        #expect(textView.selectedRange == NSRange(location: insertionLocation + 1, length: 0))
    }
}

extension IOSTextAdapterIntegrationTests {
    @Test("IME確定後の括弧ペアは行頭字下げを消し、キャレットをペア内へ置く")
    func imeCommitAppliesPostChangeD055Rules() async {
        let harness = makeHarness(initialText: "　")
        let textView = harness.textView
        textView.selectedRange = NSRange(location: 1, length: 0)
        textView.setMarkedText("「」", selectedRange: NSRange(location: 2, length: 0))
        #expect(textView.markedTextRange != nil)

        // 実IMEと同じく、変換中の本文通知ではモデル同期とPlugin介入を止める。
        harness.coordinator.textViewDidChange(textView)
        #expect(harness.changes.received.isEmpty)

        textView.unmarkText()
        for _ in 0 ..< 6 {
            await advanceMainRunLoop()
        }

        #expect(textView.text == "「」")
        #expect(textView.selectedRange == NSRange(location: 1, length: 0))
        #expect(harness.changes.received.last == "「」")

        for _ in 0 ..< 2 {
            #expect(harness.undoManager.canUndo)
            harness.undoManager.undo()
            #expect(textView.text == "　「」")
            #expect(textView.selectedRange == NSRange(location: 3, length: 0))
            #expect(harness.changes.received.last == "　「」")

            #expect(harness.undoManager.canRedo)
            harness.undoManager.redo()
            #expect(textView.text == "「」")
            #expect(textView.selectedRange == NSRange(location: 1, length: 0))
            #expect(harness.changes.received.last == "「」")
        }
    }

    @Test("Editor commandはexact選択を置換し、Undo対象として登録する")
    func editorCommandReplacesSelectionWithUndo() throws {
        let harness = makeHarness(initialText: "本文を選択")
        let textView = harness.textView
        let session = EditorCommandSession()
        harness.coordinator.registerCommandSurface(with: session)
        textView.selectedRange = NSRange(location: 3, length: 1)

        let commandID = session.requestSelectionSnapshot()
        harness.coordinator.applyEditorCommandIfNeeded(
            session.pendingCommand,
            session: session,
            textView: textView
        )
        let snapshot = try #require(session.selectionSnapshot)
        #expect(snapshot.text == "選")

        session.replaceSelection(id: commandID, text: "……")
        harness.coordinator.applyEditorCommandIfNeeded(
            session.pendingCommand,
            session: session,
            textView: textView
        )

        #expect(textView.text == "本文を……択")
        #expect(textView.selectedRange == NSRange(location: 5, length: 0))
        #expect(harness.undoManager.canUndo)

        harness.undoManager.undo()
        #expect(textView.text == "本文を選択")
        #expect(harness.changes.received.last == "本文を選択")
    }

    @Test("標準文字入力はnative UndoManagerでUndoとRedoを往復する")
    func standardInputUsesNativeUndoManager() {
        let harness = makeHarness(initialText: "本文")
        let textView = harness.textView
        textView.selectedRange = NSRange(location: 2, length: 0)
        textView.insertText("追")

        #expect(textView.text == "本文追")
        #expect(harness.undoManager.canUndo)

        harness.undoManager.undo()
        #expect(textView.text == "本文")
        #expect(harness.changes.received.last == "本文")

        #expect(harness.undoManager.canRedo)
        harness.undoManager.redo()
        #expect(textView.text == "本文追")
        #expect(harness.changes.received.last == "本文追")
    }

    @Test("標準pasteはnative UndoManagerでUndoとRedoを往復する")
    func standardPasteUsesNativeUndoManager() async {
        let harness = makeHarness(initialText: "本文")
        let textView = harness.textView
        textView.selectedRange = NSRange(location: 2, length: 0)
        textView.paste(itemProviders: [NSItemProvider(object: "本文" as NSString)])

        for _ in 0 ..< 20 where textView.text != "本文本文" {
            await Task.yield()
        }

        #expect(textView.text == "本文本文")
        #expect(harness.undoManager.canUndo)

        harness.undoManager.undo()
        #expect(textView.text == "本文")
        #expect(harness.changes.received.last == "本文")

        #expect(harness.undoManager.canRedo)
        harness.undoManager.redo()
        #expect(textView.text == "本文本文")
        #expect(harness.changes.received.last == "本文本文")
    }

    @Test("確定全文captureはUITextViewが所有する最新本文を読み取り専用で返す")
    func committedTextCaptureUsesTextViewOwnership() {
        let harness = makeHarness(initialText: "モデル側の旧本文")
        let textView = harness.textView
        let session = EditorCommandSession()
        harness.coordinator.registerCommandSurface(with: session)
        textView.text = "UITextViewが所有する本文😀"
        let selection = textView.selectedRange

        let result = session.captureActiveCommittedText()

        #expect(result == .captured("UITextViewが所有する本文😀"))
        #expect(textView.selectedRange == selection)
        #expect(!harness.undoManager.canUndo)
        #expect(harness.changes.received.isEmpty)
    }

    @Test("選択context menuはexact snapshotを渡し、本文とUndoを変更しない")
    func selectionContextMenuUsesExactSnapshot() throws {
        let harness = makeHarness(initialText: "前😀猫後")
        let textView = harness.textView
        let session = EditorCommandSession()
        harness.coordinator.registerCommandSurface(with: session)
        let range = (textView.text as NSString).range(of: "😀猫")
        textView.selectedRange = range

        let command = EditorSelectionContextMenuCommand(
            title: "校正用プロンプトをコピー",
            systemImageName: "checkmark.bubble"
        ) { snapshot in
            harness.changes.contextMenuSnapshots.append(snapshot)
        }
        let snapshot = try #require(
            harness.coordinator.selectionContextMenuSnapshot(in: textView, menuRange: range)
        )
        let box = IOSSelectionContextMenuActionBox(
            command: command,
            snapshot: snapshot,
            surfaceToken: harness.coordinator.commandSurfaceToken,
            contentRevision: harness.coordinator.aiContentRevision,
            selectionRevision: harness.coordinator.aiSelectionRevision
        )

        harness.coordinator.performSelectionContextMenuCommand(box)

        #expect(harness.changes.contextMenuSnapshots == [
            EditorSelectionContextMenuSnapshot(text: "😀猫", range: range)
        ])
        #expect(textView.text == "前😀猫後")
        #expect(!harness.undoManager.canUndo)
        #expect(harness.changes.received.isEmpty)
    }

    @Test("設定は表示属性だけを更新し、D-055の96pt表示余白を本文へ加えない")
    func configurationAndViewportDoNotMutateText() {
        let harness = makeHarness(initialText: "本文")
        let configuration = EditorConfiguration()

        harness.coordinator.applyConfigurationIfNeeded(configuration, to: harness.textView)
        harness.coordinator.applyConfigurationIfNeeded(configuration, to: harness.textView)

        #expect(harness.textView.text == "本文")
        #expect(IOSViewport.bottomWritingClearance == 96)
        #expect(harness.coordinator.textStorageAttributeApplicationCount == 1)
        #expect(harness.changes.received.isEmpty)
    }
}
#endif
