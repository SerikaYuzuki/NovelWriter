#if canImport(UIKit) && !canImport(AppKit)
import UIKit

extension IOSTextAdapter.Coordinator {
    func applySelectionRequestIfNeeded(
        _ request: EditorSelectionRequest?,
        textView: UITextView
    ) {
        guard let request, lastAppliedSelectionRequestID != request.id else { return }
        guard Range(request.range, in: textView.text) != nil else { return }

        lastAppliedSelectionRequestID = request.id
        textView.selectedRange = request.range
        IOSViewport.reveal(range: request.range, in: textView)
        textView.becomeFirstResponder()
    }

    func applyPluginReplacement(
        range: NSRange,
        text: String,
        caretOffset: Int,
        textView: UITextView
    ) {
        guard applyInternalReplacement(
            range: range,
            text: text,
            caretOffset: caretOffset,
            textView: textView
        ) else { return }
        notifyCommittedText(from: textView)
    }

    /// `UITextView`の正規入力経路を用い、Plugin置換を一回のUndo対象にする。
    ///
    /// `insertText` / `deleteBackward`を使うことでtyping attributesとUIKitのUndo
    /// 登録を維持する。本文の正を外部Bindingへ移さず、処理中のdelegate再入だけを
    /// `isApplyingPluginReplacement`で抑止する。
    @discardableResult
    func applyInternalReplacement(
        range: NSRange,
        text: String,
        caretOffset: Int,
        textView: UITextView
    ) -> Bool {
        performInternalReplacement(
            range: range,
            text: text,
            resultingSelection: NSRange(location: range.location + caretOffset, length: 0),
            textView: textView
        )
    }

    /// `UITextView`のnative UndoManagerを唯一の履歴所有者にする。標準typing／pasteと
    /// Plugin置換を別managerへ分断せず、話切替時だけ同じmanagerをclearする。
    ///
    /// UIKitの自動登録はIME確定とPlugin置換を同じ暗黙groupへ入れるとRedoのselectionを
    /// 壊すことがある。Plugin置換中だけ自動登録を止め、同じnative managerへexactな
    /// 逆置換を一件登録する。標準typing／pasteの自動登録には介入しない。
    @discardableResult
    private func performInternalReplacement(
        range: NSRange,
        text: String,
        resultingSelection: NSRange,
        textView: UITextView
    ) -> Bool {
        let source = textView.text ?? ""
        guard textView.isEditable,
              let sourceRange = Range(range, in: source) else { return false }

        let expected = (source as NSString).replacingCharacters(in: range, with: text)
        guard Range(resultingSelection, in: expected) != nil else { return false }

        let originalSelection = textView.selectedRange
        let replacedText = String(source[sourceRange])
        let undoManager = textView.undoManager
        observedInternalTextChange = false
        isApplyingPluginReplacement = true
        undoManager?.disableUndoRegistration()

        textView.selectedRange = range
        if text.isEmpty {
            if range.length > 0 {
                textView.deleteBackward()
            }
        } else {
            textView.insertText(text)
        }
        undoManager?.enableUndoRegistration()
        isApplyingPluginReplacement = false

        guard textView.text == expected else {
            textView.selectedRange = originalSelection
            return false
        }

        if source != expected, !observedInternalTextChange {
            advanceAIContentRevision()
        }
        textView.selectedRange = resultingSelection
        IOSViewport.reveal(range: textView.selectedRange, in: textView)

        if source != expected {
            registerUndo(
                inverseRange: NSRange(location: range.location, length: (text as NSString).length),
                replacedText: replacedText,
                originalSelection: originalSelection,
                textView: textView,
                surfaceToken: commandSurfaceToken
            )
        }
        return true
    }

    private func registerUndo(
        inverseRange: NSRange,
        replacedText: String,
        originalSelection: NSRange,
        textView: UITextView,
        surfaceToken: EditorSurfaceToken
    ) {
        guard commandSurfaceToken == surfaceToken else { return }
        guard let undoManager = textView.undoManager else { return }
        let pendingRegistration = IOSPendingUndoRegistration(
            inverseRange: inverseRange,
            replacedText: replacedText,
            originalSelection: originalSelection,
            surfaceToken: surfaceToken
        )
        let isWaitingForUIKitGroup = undoManager.groupingLevel > 0 &&
            !undoManager.isUndoing &&
            !undoManager.isRedoing
        guard undoManager.isUndoRegistrationEnabled, !isWaitingForUIKitGroup else {
            pendingUndoRegistrations.append(pendingRegistration)
            schedulePendingUndoFlush()
            return
        }

        performUndoRegistration(
            pendingRegistration,
            textView: textView,
            undoManager: undoManager
        )
    }

    private func performUndoRegistration(
        _ pending: IOSPendingUndoRegistration,
        textView: UITextView,
        undoManager: UndoManager
    ) {
        let registration = { [weak textView, undoManager, self] in
            guard let textView else { return }
            undoManager.registerUndo(withTarget: self) { [weak textView] coordinator in
                guard let textView,
                      coordinator.commandSurfaceToken == pending.surfaceToken,
                      coordinator.textView === textView else { return }
                _ = coordinator.performInternalReplacement(
                    range: pending.inverseRange,
                    text: pending.replacedText,
                    resultingSelection: pending.originalSelection,
                    textView: textView
                )
            }
        }

        // IMEの暗黙groupが閉じた後のR5は独立groupにする。Undo／Redo中はmanagerが
        // 作成済みの逆方向groupへ登録する必要があるため、明示groupを追加しない。
        let needsExplicitGroup = undoManager.groupingLevel == 0 &&
            !undoManager.isUndoing &&
            !undoManager.isRedoing
        guard needsExplicitGroup else {
            registration()
            return
        }

        let groupsByEvent = undoManager.groupsByEvent
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        registration()
        undoManager.endUndoGrouping()
        undoManager.groupsByEvent = groupsByEvent
    }

    func flushPendingUndoRegistrations() {
        guard !pendingUndoRegistrations.isEmpty,
              let textView,
              let undoManager = textView.undoManager else { return }
        let isWaitingForUIKitGroup = undoManager.groupingLevel > 0 &&
            !undoManager.isUndoing &&
            !undoManager.isRedoing
        guard undoManager.isUndoRegistrationEnabled, !isWaitingForUIKitGroup else { return }

        let registrations = pendingUndoRegistrations
        pendingUndoRegistrations.removeAll()
        for registration in registrations where registration.surfaceToken == commandSurfaceToken {
            registerUndo(
                inverseRange: registration.inverseRange,
                replacedText: registration.replacedText,
                originalSelection: registration.originalSelection,
                textView: textView,
                surfaceToken: registration.surfaceToken
            )
        }
    }

    func schedulePendingUndoFlush() {
        guard !isPendingUndoFlushScheduled else { return }
        isPendingUndoFlushScheduled = true
        RunLoop.main.perform { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPendingUndoFlushScheduled = false
                self.flushPendingUndoRegistrations()
            }
        }
    }
}

extension IOSTextAdapter.Coordinator {
    func applyConfigurationIfNeeded(
        _ configuration: EditorConfiguration,
        to textView: UITextView,
        force: Bool = false
    ) {
        let needsApply = force || lastAppliedConfiguration != configuration
        if textView.markedTextRange != nil {
            if needsApply {
                deferredConfiguration = configuration
            }
            return
        }

        guard needsApply || deferredConfiguration == configuration else {
            deferredConfiguration = nil
            return
        }

        apply(configuration, to: textView)
        lastAppliedConfiguration = configuration
        deferredConfiguration = nil
    }

    private func apply(_ configuration: EditorConfiguration, to textView: UITextView) {
        let font = UIFont(name: configuration.fontName, size: configuration.fontSize) ??
            UIFont.systemFont(ofSize: configuration.fontSize)
        let textColor = UIColor(hex: configuration.textColorHex) ??
            UIColor(hex: EditorConfiguration.defaultTextColorHex) ??
            .label
        let backgroundColor = UIColor(hex: configuration.backgroundColorHex) ??
            UIColor(hex: EditorConfiguration.defaultBackgroundColorHex) ??
            .systemBackground
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = configuration.lineHeightMultiple

        textView.font = font
        textView.textColor = textColor
        textView.tintColor = textColor
        textView.backgroundColor = backgroundColor
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle
        ]
        textView.textContainerInset = IOSViewport.textContainerInset
        textView.textStorage.addAttributes(
            [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: paragraphStyle
            ],
            range: NSRange(location: 0, length: (textView.text as NSString).length)
        )
        textStorageAttributeApplicationCount += 1
    }
}

private extension UIColor {
    convenience init?(hex: String) {
        let normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingPrefix("#")
        guard normalized.count == 6, let value = Int(normalized, radix: 16) else { return nil }

        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        self.init(red: red, green: green, blue: blue, alpha: 1)
    }
}
#endif
