import AppKit
import SwiftUI

/// Floating panel that can take keyboard input without activating the app.
final class ChatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // Esc hides the window, wherever focus is.
    override func sendEvent(_ event: NSEvent) {
        // Quick bar: Tab switches service, ⌘Return opens the previous chat.
        if event.type == .keyDown, AppState.shared.quickBarMode {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 48, flags.isEmpty {
                AppState.shared.toggleService()
                return
            }
            if event.keyCode == 36, flags == .command {
                PanelController.shared.expandFromBar(sending: nil, newChat: false)
                return
            }
        }
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

        // Quick bar: ⌘V attaches copied files and images, ⌘⇧S takes a screenshot.
        if state.quickBarMode {
            if flags == .command, key == "v", state.attachFromPasteboard() { return true }
            if flags == [.command, .shift], key == "s" {
                PanelController.shared.captureScreenshot()
                return true
            }
        }

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

/// The window's background. It also takes file and image drops for the quick bar.
/// This is done in AppKit because SwiftUI's onDrop doesn't reach areas covered by
/// AppKit views, and the whole bar is covered by the drag handle.
final class DropEffectView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes([.fileURL, .png, .tiff] + promiseTypes)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    private func setTargeted(_ targeted: Bool) {
        let state = AppState.shared
        if state.dropTargeted != targeted { state.dropTargeted = targeted }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard AppState.shared.quickBarMode else { return [] }
        NSLog("Mini Chat: drag entered")
        setTargeted(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        AppState.shared.quickBarMode ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setTargeted(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setTargeted(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setTargeted(false)
        let state = AppState.shared
        guard state.quickBarMode else { return false }
        let pasteboard = sender.draggingPasteboard
        defer { state.focusTick += 1 }

        // 1. Real files (Finder, Desktop).
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            NSLog("Mini Chat: dropped %ld file(s)", urls.count)
            state.addAttachments(urls)
            return true
        }
        // 2. Promised files (the floating screenshot thumbnail, Photos, Mail).
        if let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !promises.isEmpty {
            NSLog("Mini Chat: dropped %ld promised file(s)", promises.count)
            let folder = AttachmentStore.newFolder()
            for promise in promises {
                promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: .main) { url, error in
                    guard error == nil else { return }
                    MainActor.assumeIsolated { AppState.shared.addAttachments([url], copy: false) }
                }
            }
            return true
        }
        // 3. Plain image data (browsers, image editors).
        if let image = NSImage(pasteboard: pasteboard), let url = AttachmentStore.save(image) {
            NSLog("Mini Chat: dropped an image")
            state.addAttachments([url], copy: false)
            return true
        }
        NSLog("Mini Chat: drop not understood: %@", pasteboard.types?.map(\.rawValue).joined(separator: ", ") ?? "")
        return false
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
    /// The full window frame to return to when the quick bar expands.
    private var barFullFrame: NSRect?
    private static let normalMinSize = NSSize(width: 360, height: 320)
    private static let barHeight: CGFloat = 64
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
        let effect = DropEffectView()
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

    /// - Parameters:
    ///   - peek: show without taking keyboard focus.
    ///   - full: always open the full window, never the quick bar.
    func show(peek: Bool = false, full: Bool = false) {
        let wasShowing = isShowing
        let state = AppState.shared
        if !wasShowing { UsageTracker.shared.recordOpen() }
        UsageTracker.shared.update(visible: true, service: state.active)
        if !wasShowing && !peek && !full && !state.quickBarMode && state.quickBarDue {
            enterBarMode()
        }
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
            if AppState.shared.quickBarMode {
                AppState.shared.focusTick += 1
            } else {
                if !peek { WebManager.shared.focusInput(service) }
                WebManager.shared.refreshTheme(service)
            }
        }
    }

    // MARK: Quick bar

    private func enterBarMode() {
        let state = AppState.shared
        let fullFrame = restingFrame ?? panel.frame
        restingFrame = nil
        barFullFrame = fullFrame
        panel.setFrameAutosaveName("")
        panel.minSize = NSSize(width: 300, height: 50)
        let bar = NSRect(x: fullFrame.minX, y: fullFrame.maxY - Self.barHeight,
                         width: fullFrame.width, height: Self.barHeight)
        panel.setFrame(bar, display: false)
        state.quickQuery = ""
        state.quickAttachments = []
        state.quickBarMode = true
    }

    /// Makes room for the attachment row (keeps the top edge where it is).
    func updateBarHeight() {
        let state = AppState.shared
        guard state.quickBarMode else { return }
        let height = state.quickAttachments.isEmpty ? Self.barHeight : Self.barHeight + 66
        var frame = panel.frame
        guard frame.height != height else { return }
        let top = frame.maxY
        frame.size.height = height
        frame.origin.y = top - height
        panel.setFrame(frame, display: true, animate: state.animations)
    }

    /// Lets you drag a box around part of the screen and attaches the result.
    func captureScreenshot() {
        let state = AppState.shared
        guard state.quickBarMode, !state.capturingScreenshot else { return }
        let url = AttachmentStore.newURL(name: "Screenshot.png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", url.path] // interactive selection, no sound

        state.capturingScreenshot = true
        panel.alphaValue = 0 // keep the bar out of the screenshot
        process.terminationHandler = { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let state = AppState.shared
                    state.capturingScreenshot = false
                    self.panel.alphaValue = 1
                    self.panel.makeKeyAndOrderFront(nil)
                    if FileManager.default.fileExists(atPath: url.path) {
                        state.addAttachments([url], copy: false)
                    }
                    state.focusTick += 1
                }
            }
        }
        do {
            try process.run()
        } catch {
            state.capturingScreenshot = false
            panel.alphaValue = 1
            NSSound.beep()
        }
    }

    /// Grows the quick bar into the full window. With text, starts a new chat
    /// and sends it. Without text, opens a new chat (or the previous one if newChat is false).
    func expandFromBar(sending text: String?, newChat: Bool = true) {
        let state = AppState.shared
        guard state.quickBarMode, let fullFrame = barFullFrame else { return }
        barFullFrame = nil
        let service = state.active
        let prompt = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        withAnimation(.easeOut(duration: 0.2)) { state.quickBarMode = false }
        panel.minSize = Self.normalMinSize
        animate(to: fullFrame) {
            if self.collapsedFrame == nil { self.panel.setFrameAutosaveName("MiniChatPanel") }
        }

        let files = newChat ? state.quickAttachments.map(\.url) : []
        state.quickAttachments = []
        if !prompt.isEmpty || !files.isEmpty {
            WebManager.shared.startChat(prompt, files: files, in: service)
        } else if newChat {
            WebManager.shared.newChat(service)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            WebManager.shared.focusInput(service)
            WebManager.shared.refreshTheme(service)
        }
    }

    /// Puts the window back to its full size after hiding from the quick bar.
    private func leaveBarModeAfterHide() {
        let state = AppState.shared
        guard state.quickBarMode else { return }
        state.quickBarMode = false
        state.quickAttachments = []
        panel.minSize = Self.normalMinSize
        if let fullFrame = barFullFrame { panel.setFrame(fullFrame, display: false) }
        barFullFrame = nil
        if collapsedFrame == nil { panel.setFrameAutosaveName("MiniChatPanel") }
    }

    func hide() {
        guard panel.isVisible else { return }
        // Closing the quick bar without asking anything doesn't count as using the chat.
        if !AppState.shared.quickBarMode { AppState.shared.lastHidden = Date() }
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
            leaveBarModeAfterHide()
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
                self.leaveBarModeAfterHide()
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
        guard !AppState.shared.pinned, !AppState.shared.capturingScreenshot else { return }
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
        guard !AppState.shared.quickBarMode else { return }
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
        guard !state.quickBarMode else { return }
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
