#if canImport(AppKit)
import AppKit
@testable import EditorKit
import Testing

@MainActor
@Suite("macOS editor read-only boundary")
struct MacEditorReadOnlyIntegrationTests {
    private final class Changes {
        var received: [String] = []
    }

    private struct Harness {
        let textView: NSTextView
        let coordinator: MacTextAdapter.Coordinator
        let changes: Changes
    }

    private func makeHarness(
        initialText: String
    ) -> Harness {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.string = initialText

        let changes = Changes()
        let coordinator = MacTextAdapter.Coordinator { changes.received.append($0) }
        coordinator.textView = textView
        textView.delegate = coordinator
        return Harness(
            textView: textView,
            coordinator: coordinator,
            changes: changes
        )
    }

    @Test("選択とcopyを保ち、通常入力・Plugin・notation置換を拒否する")
    func preservesSelectionAndRejectsMutations() throws {
        let harness = makeHarness(initialText: "本文を選択")
        let session = EditorCommandSession()
        harness.coordinator.registerCommandSurface(with: session)
        let selection = NSRange(location: 3, length: 1)
        harness.textView.setSelectedRange(selection)

        harness.coordinator.updateDesiredEditability(false, textView: harness.textView)

        #expect(!harness.textView.isEditable)
        #expect(harness.textView.isSelectable)
        #expect(harness.textView.selectedRange() == selection)

        harness.textView.insertText("追", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(harness.textView.string == "本文を選択")

        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.clearContents()
        pasteboard.setString("貼付", forType: .string)
        #expect(!harness.textView.readSelection(from: pasteboard, type: .string))
        #expect(harness.textView.string == "本文を選択")

        #expect(!harness.coordinator.textView(
            harness.textView,
            shouldChangeTextIn: selection,
            replacementString: "\n"
        ))

        let commandID = session.requestSelectionSnapshot()
        harness.coordinator.applyEditorCommandIfNeeded(
            session.pendingCommand,
            session: session,
            textView: harness.textView
        )
        let snapshot = try #require(session.selectionSnapshot)
        #expect(snapshot.text == "選")

        session.replaceSelection(id: commandID, text: "……")
        harness.coordinator.applyEditorCommandIfNeeded(
            session.pendingCommand,
            session: session,
            textView: harness.textView
        )

        #expect(session.rejectedCommandID == commandID)
        #expect(harness.textView.string == "本文を選択")
        #expect(harness.changes.received.isEmpty)
    }

    @Test("作品遷移の再開は読み取り専用の入力権限を覆さない")
    func transitionResumeRespectsDesiredState() {
        let harness = makeHarness(initialText: "本文")
        let session = EditorCommandSession()
        harness.coordinator.registerDocumentLifecycle(with: session)

        #expect(session.prepareForDocumentTransition())
        #expect(!harness.textView.isEditable)
        #expect(harness.coordinator.isEditingSuspendedForDocumentTransition)

        harness.coordinator.updateDesiredEditability(false, textView: harness.textView)

        session.resumeAfterDocumentTransition()

        #expect(!harness.textView.isEditable)
        #expect(!harness.coordinator.isEditingSuspendedForDocumentTransition)
        #expect(!harness.coordinator.desiredIsEditable)

        harness.coordinator.updateDesiredEditability(true, textView: harness.textView)
        #expect(harness.textView.isEditable)
    }

    @Test("IME変換中の切替は確定本文を通知してから入力を止める")
    func toggleCommitsMarkedTextBeforeLocking() {
        let harness = makeHarness(initialText: "本文")
        harness.textView.setSelectedRange(NSRange(location: 2, length: 0))
        harness.textView.setMarkedText(
            "仮",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(harness.textView.hasMarkedText())

        harness.coordinator.updateDesiredEditability(false, textView: harness.textView)

        #expect(!harness.textView.hasMarkedText())
        #expect(!harness.textView.isEditable)
        #expect(harness.changes.received.last == harness.textView.string)
    }
}
#endif

#if canImport(UIKit) && !canImport(AppKit)
@testable import EditorKit
import Testing
import UIKit

@MainActor
@Suite("iOS editor read-only boundary", .serialized)
struct IOSEditorReadOnlyIntegrationTests {
    private final class Changes {
        var received: [String] = []
    }

    private struct Harness {
        let textView: IOSTextView
        let coordinator: IOSTextAdapter.Coordinator
        let changes: Changes
        let window: UIWindow
    }

    private func makeHarness(initialText: String) -> Harness {
        let textView = IOSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.text = initialText

        let changes = Changes()
        let coordinator = IOSTextAdapter.Coordinator { changes.received.append($0) }
        coordinator.textView = textView
        coordinator.lastNotifiedCommittedText = initialText
        textView.delegate = coordinator
        textView.editorCoordinator = coordinator

        let viewController = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 932))
        window.rootViewController = viewController
        textView.frame = viewController.view.bounds
        viewController.view.addSubview(textView)
        window.makeKeyAndVisible()
        _ = textView.becomeFirstResponder()
        return Harness(
            textView: textView,
            coordinator: coordinator,
            changes: changes,
            window: window
        )
    }

    private func advanceMainRunLoop() async {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform {
                continuation.resume()
            }
        }
    }

    @Test("選択とcopyを保ち、入力・paste・Plugin・notation置換を拒否する")
    func preservesSelectionAndRejectsMutations() async throws {
        let harness = makeHarness(initialText: "本文を選択")
        defer { harness.window.isHidden = true }
        let session = EditorCommandSession()
        harness.coordinator.registerCommandSurface(with: session)
        let selection = NSRange(location: 3, length: 1)
        harness.textView.selectedRange = selection

        harness.coordinator.updateDesiredEditability(false, textView: harness.textView)

        #expect(!harness.textView.isEditable)
        #expect(harness.textView.isSelectable)
        #expect(harness.textView.isScrollEnabled)
        #expect(harness.textView.selectedRange == selection)

        harness.textView.insertText("追")
        harness.textView.paste(itemProviders: [NSItemProvider(object: "貼付" as NSString)])
        for _ in 0 ..< 6 {
            await advanceMainRunLoop()
        }
        #expect(harness.textView.text == "本文を選択")
        #expect(!harness.coordinator.textView(
            harness.textView,
            shouldChangeTextIn: selection,
            replacementText: "\n"
        ))

        let commandID = session.requestSelectionSnapshot()
        harness.coordinator.applyEditorCommandIfNeeded(
            session.pendingCommand,
            session: session,
            textView: harness.textView
        )
        let snapshot = try #require(session.selectionSnapshot)
        #expect(snapshot.text == "選")

        session.replaceSelection(id: commandID, text: "……")
        harness.coordinator.applyEditorCommandIfNeeded(
            session.pendingCommand,
            session: session,
            textView: harness.textView
        )

        #expect(session.rejectedCommandID == commandID)
        #expect(harness.textView.text == "本文を選択")
        #expect(harness.changes.received.isEmpty)
    }

    @Test("作品遷移の再開は読み取り専用の入力権限を覆さない")
    func transitionResumeRespectsDesiredState() {
        let harness = makeHarness(initialText: "本文")
        defer { harness.window.isHidden = true }
        let session = EditorCommandSession()
        harness.coordinator.registerDocumentLifecycle(with: session)

        #expect(session.prepareForDocumentTransition())
        #expect(!harness.textView.isEditable)
        #expect(harness.coordinator.isEditingSuspendedForDocumentTransition)

        harness.coordinator.updateDesiredEditability(false, textView: harness.textView)

        session.resumeAfterDocumentTransition()

        #expect(!harness.textView.isEditable)
        #expect(!harness.coordinator.isEditingSuspendedForDocumentTransition)
        #expect(!harness.coordinator.desiredIsEditable)

        harness.coordinator.updateDesiredEditability(true, textView: harness.textView)
        #expect(harness.textView.isEditable)
    }

    @Test("IME変換中の切替は確定本文を通知してから入力を止める")
    func toggleCommitsMarkedTextBeforeLocking() async {
        let harness = makeHarness(initialText: "本文")
        defer { harness.window.isHidden = true }
        harness.textView.selectedRange = NSRange(location: 2, length: 0)
        harness.textView.setMarkedText("仮", selectedRange: NSRange(location: 1, length: 0))
        harness.coordinator.textViewDidChange(harness.textView)
        #expect(harness.textView.markedTextRange != nil)
        #expect(harness.changes.received.isEmpty)

        harness.coordinator.updateDesiredEditability(false, textView: harness.textView)
        await advanceMainRunLoop()

        #expect(harness.textView.markedTextRange == nil)
        #expect(!harness.textView.isEditable)
        #expect(harness.changes.received.last == harness.textView.text)
    }
}
#endif
