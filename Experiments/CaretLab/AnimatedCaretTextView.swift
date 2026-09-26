import AppKit
import QuartzCore

/// 検証版だけが生成するTextKit 2ビュー。入力・marked text・候補座標はsuperが所有する。
final class AnimatedCaretTextView: NSTextView {
    private let indicator = PassiveInsertionIndicator(frame: .zero)
    private var lastTarget: NSRect?
    private var isRefreshingCaret = false
    private var isTrackingMouse = false
    private var isInsertingNewline = false
    private var hasConfiguredIndicator = false
    private var eventObservers: [CaretEventObserver] = []
    private(set) var animationCount = 0
    private(set) var markedAnimationCount = 0
    private(set) var observedScrollChangeCount = 0
    var displayedCaretFrame: NSRect? {
        indicator.isHidden ? nil : indicator.frame
    }

    var isMovementAnimating: Bool {
        indicator.layer?.animation(forKey: "caretPosition") != nil
    }

    var motionEnabled = CaretExperimentPreferences.isEnabled {
        didSet {
            guard oldValue != motionEnabled else { return }
            refreshCaret(animate: false)
            updateInsertionPointStateAndRestartTimer(true)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        configureIndicator()
    }

    override init(frame: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        configureIndicator()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureIndicator()
    }

    private var usesAnimatedIndicator: Bool {
        motionEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion &&
            isEditable && window?.isKeyWindow == true && window?.firstResponder === self &&
            selectedRange().length == 0
    }

    override var shouldDrawInsertionPoint: Bool {
        usesAnimatedIndicator ? false : super.shouldDrawInsertionPoint
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        enclosingScrollView?.contentView.postsBoundsChangedNotifications = true
        refreshCaret(animate: false)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        refreshCaret(animate: false)
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            hideIndicator()
        }
        return accepted
    }

    override func layout() {
        super.layout()
        refreshCaret(animate: true)
    }

    override func keyDown(with event: NSEvent) {
        super.keyDown(with: event)
        refreshCaret(animate: true)
    }

    override func mouseDown(with event: NSEvent) {
        isTrackingMouse = true
        super.mouseDown(with: event)
        isTrackingMouse = false
        refreshCaret(animate: false)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        refreshCaret(animate: true)
    }

    override func insertNewline(_ sender: Any?) {
        // 字下げpluginの中間選択では描画せず、標準編集が完了した位置へ一度だけ動かす。
        isInsertingNewline = true
        super.insertNewline(sender)
        isInsertingNewline = false
        refreshCaret(animate: true, afterNewline: true)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        refreshCaret(animate: true)
    }

    override func unmarkText() {
        super.unmarkText()
        refreshCaret(animate: true)
    }

    private func configureIndicator() {
        guard !hasConfiguredIndicator else { return }
        hasConfiguredIndicator = true
        indicator.wantsLayer = true
        indicator.displayMode = .hidden
        indicator.setAccessibilityElement(false)
        indicator.isHidden = true
        addSubview(indicator)
        observe(NSTextView.didChangeSelectionNotification, object: self) { [weak self] _ in
            self?.selectionChanged()
        }
        observe(NSView.boundsDidChangeNotification) { [weak self] notification in
            self?.scrolled(notification)
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observe(name) { [weak self] notification in self?.windowFocusChanged(notification) }
        }
        observe(CaretExperimentPreferences.didChange) { [weak self] _ in self?.preferencesChanged() }
        observe(NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                center: NSWorkspace.shared.notificationCenter) { [weak self] _ in
            self?.accessibilityChanged()
        }
    }

    private func observe(_ name: Notification.Name, object: AnyObject? = nil,
                         center: NotificationCenter = .default, handler: @escaping (Notification) -> Void) {
        // NSTextView manages its own registrations when reparented.
        // A separate observer keeps this experiment independent of that lifecycle.
        let observer = CaretEventObserver(handler: handler)
        eventObservers.append(observer)
        center.addObserver(observer, selector: #selector(CaretEventObserver.receive), name: name, object: object)
    }

    private func selectionChanged() {
        refreshCaret(animate: !isTrackingMouse)
    }

    private func scrolled(_ notification: Notification) {
        guard notification.object as? NSClipView === enclosingScrollView?.contentView else { return }
        observedScrollChangeCount += 1
        indicator.layer?.removeAnimation(forKey: "caretPosition")
        refreshCaret(animate: false)
    }

    private func windowFocusChanged(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        refreshCaret(animate: false)
    }

    private func preferencesChanged() {
        motionEnabled = CaretExperimentPreferences.isEnabled
    }

    private func accessibilityChanged() {
        refreshCaret(animate: false)
        updateInsertionPointStateAndRestartTimer(true)
    }

    private func hideIndicator() {
        indicator.layer?.removeAllAnimations()
        indicator.displayMode = .hidden
        indicator.isHidden = true
        lastTarget = nil
    }

    /// 候補ウインドウに返すfirstRectはoverrideしない。標準座標を読むだけにする。
    func refreshCaret(animate: Bool, afterNewline: Bool = false) {
        guard !isRefreshingCaret, !isInsertingNewline else { return }
        isRefreshingCaret = true
        defer { isRefreshingCaret = false }
        guard usesAnimatedIndicator, let window, selectedRange().location != NSNotFound else {
            hideIndicator()
            return
        }
        let screenRect = firstRect(forCharacterRange: NSRange(location: selectedRange().location, length: 0),
                                   actualRange: nil)
        var target = convert(window.convertFromScreen(screenRect), from: nil)
        guard target.height > 0, target.minX.isFinite, target.minY.isFinite else {
            hideIndicator()
            return
        }
        target.size.width = 2
        guard visibleRect.intersects(target) else {
            hideIndicator()
            return
        }
        indicator.color = insertionPointColor
        indicator.displayMode = .automatic
        indicator.isHidden = false
        guard target != lastTarget else {
            if !animate || isTrackingMouse {
                indicator.layer?.removeAnimation(forKey: "caretPosition")
            }
            return
        }
        let shouldAnimate = CaretMotionPolicy.shouldAnimate(
            from: lastTarget, to: target, requested: animate && !isTrackingMouse, afterNewline: afterNewline
        )
        let displayedPosition = indicator.layer?.presentation()?.position ?? indicator.layer?.position
        indicator.layer?.removeAnimation(forKey: "caretPosition")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        indicator.frame = target
        CATransaction.commit()
        lastTarget = target
        if shouldAnimate, let displayedPosition, let layer = indicator.layer {
            let movement = CABasicAnimation(keyPath: "position")
            movement.fromValue = displayedPosition
            movement.toValue = layer.position
            movement.duration = CaretMotionPolicy.duration
            movement.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(movement, forKey: "caretPosition")
            animationCount += 1
            if hasMarkedText() {
                markedAnimationCount += 1
            }
        }
    }
}

private final class PassiveInsertionIndicator: NSTextInsertionIndicator {
    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }
}
