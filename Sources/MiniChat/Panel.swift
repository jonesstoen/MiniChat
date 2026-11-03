import AppKit
import SwiftUI

/// Floating panel that can take keyboard input without activating the app.
final class ChatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // Esc hides the window, wherever focus is.
    override func sendEvent(_ event: NSEvent) {
        // Command palette: arrow keys and Esc.
        if event.type == .keyDown, AppState.shared.showPalette, attachedSheet == nil {
            switch event.keyCode {
            case 125: AppState.shared.movePaletteSelection(1); return   // ↓
            case 126: AppState.shared.movePaletteSelection(-1); return  // ↑
            case 53: AppState.shared.closePalette(); return             // Esc
            default: break
            }
        }
        if event.type == .keyDown,
           event.keyCode == 53,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.function).isEmpty,
           attachedSheet == nil {
            PanelController.shared.hide()
            return
        }
        super.sendEvent(event)
    }

    // The panel has no visible menu, so shortcuts are handled here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let state = AppState.shared
        let web = WebManager.shared

        if flags == .command {
            switch key {
            case "w": PanelController.shared.hide(); return true
            case "1": state.switchTo(.chatgpt); return true
            case "2": state.switchTo(.claude); return true
            case "n": web.newChat(state.active); return true
            case "r": web.reload(state.active); return true
            case "[": web.webView(for: state.active).goBack(); return true
            case "]": web.webView(for: state.active).goForward(); return true
            case "e": PanelController.shared.toggleExpanded(); return true
            case "j": state.togglePalette(); return true
            case ",": SettingsWindowController.shared.show(); return true
            case "d": state.toggleBookmarkCurrent(); return true
            case "p": state.togglePinned(); return true
            case "y":
                if state.focusMode { state.setHeaderRevealed(true) }
                state.showHistory.toggle()
                return true
            default: break
            }
            let editing: [String: Selector] = [
                "x": #selector(NSText.cut(_:)),
                "c": #selector(NSText.copy(_:)),
                "v": #selector(NSText.paste(_:)),
                "a": #selector(NSText.selectAll(_:)),
                "z": Selector(("undo:")),
            ]
            if let selector = editing[key], NSApp.sendAction(selector, to: nil, from: self) {
                return true
            }
        } else if flags == [.command, .shift], key == "z" {
            if NSApp.sendAction(Selector(("redo:")), to: nil, from: self) { return true }
        } else if flags == [.command, .shift], key == "h" {
            state.toggleContentHidden()
            return true
        } else if flags == [.command, .shift], key == "f" {
            state.toggleFocusMode()
            return true
        } else if flags.subtracting([.function, .numericPad]) == [.control, .option] {
            switch event.keyCode {
            case 123: PanelController.shared.snap(.left); return true   // ⌃⌥←
            case 124: PanelController.shared.snap(.right); return true  // ⌃⌥→
            case 126: PanelController.shared.snap(.center); return true // ⌃⌥↑
            default: break
            }
        } else if flags == .control, event.keyCode == 48 { // Ctrl+Tab
            state.toggleService()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Drag this to move the window (used as the top bar background).
final class DragHandleView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            PanelController.shared.toggleExpanded()
        } else {
            window?.performDrag(with: event)
        }
    }
}

/// Invisible handle in the bottom-right corner for resizing the window.
final class ResizeHandleView: NSView {
    private var startFrame = NSRect.zero
    private var startPoint = NSPoint.zero

    override func mouseDown(with event: NSEvent) {
        startFrame = window?.frame ?? .zero
        startPoint = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let point = NSEvent.mouseLocation
        let width = max(window.minSize.width, startFrame.width + (point.x - startPoint.x))
        let height = max(window.minSize.height, startFrame.height - (point.y - startPoint.y))
        let frame = NSRect(x: startFrame.minX, y: startFrame.maxY - height, width: width, height: height)
        window.setFrame(frame, display: true)
    }
}

@MainActor
final class PanelController {
    static let shared = PanelController()
    static let cornerRadius: CGFloat = 18

    private lazy var panel: ChatPanel = makePanel()
    private var generation = 0
    private var restingFrame: NSRect?
    private var collapsedFrame: NSRect?
    private var hoverTimer: Timer?

    var isShowing: Bool { panel.isVisible && panel.alphaValue > 0.5 }

    private func makePanel() -> ChatPanel {
        let panel = ChatPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 640),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 360, height: 320)

        // Frosted, translucent background with large rounded corners.
        let radius = Self.cornerRadius
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.roundedMask(radius: radius)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = radius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        let hosting = NSHostingView(rootView: RootView(state: AppState.shared))
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect

        // When unpinned: hide the window when clicking outside.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { _ in
            MainActor.assumeIsolated { PanelController.shared.panelResignedKey() }
        }

        if !panel.setFrameUsingName("MiniChatPanel") {
            panel.center()
        }
        panel.setFrameAutosaveName("MiniChatPanel")
        return panel
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.set()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    func toggle() {
        if panel.isVisible && panel.isKeyWindow && panel.alphaValue > 0.9 {
            hide()
        } else {
            show()
        }
    }

    /// ⌥⇧Space: show/hide without taking keyboard focus from the current app.
    func togglePeek() {
        if isShowing {
            hide()
        } else {
            show(peek: true)
        }
    }

    func show(peek: Bool = false) {
        if !isShowing { UsageTracker.shared.recordOpen() }
        UsageTracker.shared.update(visible: true, service: AppState.shared.active)
        generation += 1
        let current = generation
        let service = AppState.shared.active
        let animated = AppState.shared.animations

        func bringToFront() {
            if peek {
                panel.orderFrontRegardless()
            } else {
                panel.makeKeyAndOrderFront(nil)
            }
        }

        if panel.isVisible && panel.alphaValue >= 1 && restingFrame == nil {
            bringToFront()
        } else if !animated {
            if let resting = restingFrame { panel.setFrame(resting, display: false) }
            restingFrame = nil
            panel.alphaValue = 1
            bringToFront()
        } else {
            // Fade in and slide up slightly.
            let target = restingFrame ?? panel.frame
            restingFrame = target
            var start = target
            start.origin.y -= 12
            panel.alphaValue = 0
            panel.setFrame(start, display: false)
            bringToFront()

            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.panel.animator().alphaValue = 1
                self.panel.animator().setFrame(target, display: true)
            }, completionHandler: {
                MainActor.assumeIsolated {
                    guard current == self.generation else { return }
                    self.restingFrame = nil
                    self.panel.invalidateShadow()
                }
            })
        }

        AppState.shared.markSeen()
        updateHoverTracking()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if !peek { WebManager.shared.focusInput(service) }
            WebManager.shared.refreshTheme(service)
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        AppState.shared.showHistory = false
        AppState.shared.showPalette = false
        UsageTracker.shared.update(visible: false, service: AppState.shared.active)
        generation += 1
        let current = generation
        let resting = restingFrame ?? panel.frame

        guard AppState.shared.animations else {
            panel.orderOut(nil)
            panel.setFrame(resting, display: false)
            panel.alphaValue = 1
            restingFrame = nil
            updateHoverTracking()
            return
        }

        restingFrame = resting
        var end = resting
        end.origin.y -= 8

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.panel.animator().alphaValue = 0
            self.panel.animator().setFrame(end, display: true)
        }, completionHandler: {
            MainActor.assumeIsolated {
                guard current == self.generation else { return }
                self.panel.orderOut(nil)
                self.panel.setFrame(resting, display: false)
                self.panel.alphaValue = 1
                self.restingFrame = nil
                self.updateHoverTracking()
            }
        })
    }

    /// Removes keyboard focus from the page (used when the chat is hidden).
    func clearWebFocus() {
        panel.makeFirstResponder(nil)
    }

    func setSystemAppearance() {
        panel.appearance = nil
    }

    // MARK: Pin

    fileprivate func panelResignedKey() {
        guard !AppState.shared.pinned else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            // Don't hide if focus only moved to one of the app's own windows
            // (sign-in, file picker, dialog, history).
            guard !AppState.shared.pinned,
                  self.panel.isVisible,
                  !self.panel.isKeyWindow,
                  self.panel.attachedSheet == nil,
                  !NSApp.windows.contains(where: { $0.isKeyWindow }) else { return }
            self.hide()
        }
    }

    // MARK: Snap to screen edge

    enum SnapPosition { case left, right, center }

    func snap(_ position: SnapPosition) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        if collapsedFrame != nil {
            collapsedFrame = nil
            AppState.shared.isExpanded = false
            panel.setFrameAutosaveName("MiniChatPanel")
        }
        let visible = screen.visibleFrame
        let margin: CGFloat = 12
        let width = min(max(panel.frame.width, panel.minSize.width), 520)
        let target: NSRect
        switch position {
        case .left:
            target = NSRect(x: visible.minX + margin, y: visible.minY + margin,
                            width: width, height: visible.height - margin * 2)
        case .right:
            target = NSRect(x: visible.maxX - margin - width, y: visible.minY + margin,
                            width: width, height: visible.height - margin * 2)
        case .center:
            let w: CGFloat = 440
            let h = min(640, visible.height - margin * 2)
            target = NSRect(x: visible.midX - w / 2, y: visible.midY - h / 2 + visible.height * 0.05,
                            width: w, height: h)
        }
        animate(to: target)
    }

    // MARK: Expand (⌘E)

    func toggleExpanded() {
        let state = AppState.shared
        if let collapsed = collapsedFrame {
            collapsedFrame = nil
            state.isExpanded = false
            animate(to: collapsed) {
                self.panel.setFrameAutosaveName("MiniChatPanel")
            }
            return
        }

        guard let screen = panel.screen ?? NSScreen.main else { return }
        let current = panel.frame
        let visible = screen.visibleFrame
        let margin: CGFloat = 20
        let width = min(max(current.width, 900), visible.width - margin * 2)
        let height = min(max(current.height, visible.height * 0.85), visible.height - margin * 2)
        var x = current.midX - width / 2
        var y = current.maxY - height // keep the top edge where it is
        x = min(max(x, visible.minX + margin), visible.maxX - margin - width)
        y = min(max(y, visible.minY + margin), visible.maxY - margin - height)

        collapsedFrame = current
        state.isExpanded = true
        panel.setFrameAutosaveName("") // don't remember the large size for next time
        animate(to: NSRect(x: x, y: y, width: width, height: height))
    }

    private func animate(to frame: NSRect, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.panel.animator().setFrame(frame, display: true)
        }, completionHandler: {
            MainActor.assumeIsolated {
                self.panel.invalidateShadow()
                completion?()
            }
        })
    }

    // MARK: Focus mode: reveal the top bar when the mouse is at the top edge

    func updateHoverTracking() {
        let needed = AppState.shared.focusMode && panel.isVisible
        if needed, hoverTimer == nil {
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
                MainActor.assumeIsolated { PanelController.shared.checkHover() }
            }
        } else if !needed {
            hoverTimer?.invalidate()
            hoverTimer = nil
            AppState.shared.setHeaderRevealed(false)
        }
    }

    private func checkHover() {
        guard panel.isVisible, AppState.shared.focusMode else {
            updateHoverTracking()
            return
        }
        let mouse = NSEvent.mouseLocation
        let frame = panel.frame
        let inside = frame.insetBy(dx: -2, dy: -2).contains(mouse)
        let fromTop = frame.maxY - mouse.y
        let state = AppState.shared

        if !state.headerRevealed {
            if inside && fromTop <= 10 { state.setHeaderRevealed(true) }
        } else if (!inside || fromTop > 60) && !state.showHistory {
            state.setHeaderRevealed(false)
        }
    }
}
