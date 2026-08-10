import Foundation
@testable import FUMINIWAIOS
import SwiftUI
import Testing
import UIKit

@MainActor
@Suite("iOS editor font settings", .serialized)
struct IOSEditorFontSettingsTests {
    @Test("未保存値と不正保存値は既定のヒラギノ明朝へ戻る")
    func invalidStoredValueFallsBackToDefault() {
        #expect(IOSEditorFontFamily(storedRawValue: nil) == .hiraginoMincho)
        #expect(IOSEditorFontFamily(storedRawValue: "unknown-font") == .hiraginoMincho)
        #expect(
            IOSEditorFontFamily(storedRawValue: IOSEditorFontFamily.hiraginoSans.rawValue) == .hiraginoSans
        )

        let configuration = IOSEditorFontPreference.configuration(storedRawValue: "broken")
        #expect(configuration.fontName == IOSEditorFontFamily.hiraginoMincho.fontName)
    }

    @Test("選択肢の日本語フォントはiOS上のPostScript名で解決できる")
    func bundledJapaneseFontsResolve() {
        #expect(UIFont(name: IOSEditorFontFamily.hiraginoMincho.fontName, size: 16) != nil)
        #expect(UIFont(name: IOSEditorFontFamily.hiraginoSans.fontName, size: 16) != nil)
    }

    @Test("UserDefaultsの変更を実UITextViewへ本文再読込なしで反映し、IME中は保留する")
    func preferenceUpdatesTextViewWithoutReloadingText() async throws {
        let environment = makeEnvironment()
        defer { environment.cleanup() }
        environment.defaults.set(
            IOSEditorFontFamily.hiraginoSans.rawValue,
            forKey: IOSEditorFontPreference.preferenceKey
        )
        let store = IOSDocumentStore(
            userDefaults: environment.defaults,
            libraryRoot: environment.root
        )
        await store.bootstrap()
        #expect(await store.makeNewDocument())

        let harness = try await makeEditorHarness(
            store: store,
            userDefaults: environment.defaults
        )
        defer { harness.cleanup() }
        let textView = harness.textView
        #expect(fontName(of: textView) == expectedFontName(for: .hiraginoSans))

        textView.text = "編集中の本文"
        textView.selectedRange = NSRange(location: 3, length: 0)
        textView.delegate?.textViewDidChange?(textView)
        let editorIdentity = ObjectIdentifier(textView)

        beginMarkedText("変換中", in: textView)
        let composingText = textView.text
        let fontBeforePreferenceChange = fontName(of: textView)
        environment.defaults.set(
            IOSEditorFontFamily.hiraginoMincho.rawValue,
            forKey: IOSEditorFontPreference.preferenceKey
        )
        await advanceMainRunLoop(iterations: 8)

        #expect(textView.markedTextRange != nil)
        #expect(textView.text == composingText)
        #expect(fontName(of: textView) == fontBeforePreferenceChange)

        textView.unmarkText()
        let didApplyFont = await waitUntil {
            fontName(of: textView) == expectedFontName(for: .hiraginoMincho)
        }

        #expect(didApplyFont)
        #expect(ObjectIdentifier(textView) == editorIdentity)
        #expect(textView.text == composingText)
        #expect(textView.markedTextRange == nil)
    }

    private func makeEditorHarness(
        store: IOSDocumentStore,
        userDefaults: UserDefaults
    ) async throws -> FontEditorHarness {
        let host = UIHostingController(
            rootView: IOSEditorPane(store: store, userDefaults: userDefaults)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 932))
        window.rootViewController = host
        host.view.frame = window.bounds
        window.makeKeyAndVisible()

        for _ in 0 ..< 20 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            if let textView = findTextView(in: host.view) {
                return FontEditorHarness(window: window, textView: textView)
            }
            await advanceMainRunLoop()
        }

        window.isHidden = true
        window.rootViewController = nil
        Issue.record("EditorのUITextViewを取得できませんでした。")
        throw FontEditorHarnessError.textViewNotFound
    }

    private func beginMarkedText(_ text: String, in textView: UITextView) {
        textView.selectedRange = NSRange(
            location: (textView.text as NSString).length,
            length: 0
        )
        textView.setMarkedText(
            text,
            selectedRange: NSRange(location: (text as NSString).length, length: 0)
        )
        textView.delegate?.textViewDidChange?(textView)
    }

    private func expectedFontName(for family: IOSEditorFontFamily) -> String {
        let font = UIFont(name: family.fontName, size: 16) ?? UIFont.systemFont(ofSize: 16)
        return font.fontName
    }

    private func fontName(of textView: UITextView) -> String? {
        textView.font?.fontName
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0 ..< 120 {
            if condition() {
                return true
            }
            await advanceMainRunLoop()
        }
        return condition()
    }

    private func advanceMainRunLoop(iterations: Int = 1) async {
        for _ in 0 ..< iterations {
            await withCheckedContinuation { continuation in
                RunLoop.main.perform {
                    continuation.resume()
                }
            }
        }
    }

    private func findTextView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView {
            return textView
        }
        for subview in view.subviews {
            if let textView = findTextView(in: subview) {
                return textView
            }
        }
        return nil
    }

    private func makeEnvironment() -> FontSettingsTestEnvironment {
        let id = UUID().uuidString
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FUMINIWA-iOS-Font-Tests-\(id)", isDirectory: true)
        let suiteName = "dev.serikayuzuki.fuminiwa.ios.font-tests.\(id)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return FontSettingsTestEnvironment(
            root: root,
            defaults: defaults,
            suiteName: suiteName
        )
    }
}

@MainActor
private struct FontEditorHarness {
    let window: UIWindow
    let textView: UITextView

    func cleanup() {
        window.isHidden = true
        window.rootViewController = nil
    }
}

private enum FontEditorHarnessError: Error {
    case textViewNotFound
}

private struct FontSettingsTestEnvironment {
    let root: URL
    let defaults: UserDefaults
    let suiteName: String

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
