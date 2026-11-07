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
            // ↑ / ↓: earlier questions, like in Terminal.
            if flags.subtracting([.function, .numericPad]).isEmpty, event.keyCode == 126 || event.keyCode == 125 {
                AppState.shared.navigatePrompts(older: event.keyCode == 126)
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
            if flags == .command, key == "o" {
                PanelController.shared.pickFiles()
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
    /// The window content, faded out while the bar grows into the full window.
    private weak var hostingView: NSView?
    private static let barWidth: CGFloat = 640

    private static func screenUnderMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Where the full window goes when the quick bar expands: along the chosen screen
    /// edge, so it stays clear of what you're working on. Keeps the window's usual size.
    private func expandedFrame(size: NSSize) -> NSRect? {
        let side = AppState.shared.expandSide
        guard side != .lastPosition else { return nil }
        let screen = panel.screen ?? Self.screenUnderMouse()
        let visible = screen.visibleFrame
        let margin: CGFloat = 6 // close to the edge, out of the way
        let width = min(size.width, visible.width - margin * 2)
        let height = min(size.height, visible.height - margin * 2)
        let x = side == .right ? visible.maxX - margin - width : visible.minX + margin
        return NSRect(x: x, y: visible.maxY - margin - height, width: width, height: height)
    }
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
        hostingView = hosting
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
        // Centered in the lower part of the screen the mouse is on, like a command bar.
        let visible = Self.screenUnderMouse().visibleFrame
        let width = min(Self.barWidth, visible.width - 40)
        let bar = NSRect(x: visible.midX - width / 2,
                         y: visible.minY + visible.height * 0.1,
                         width: width, height: Self.barHeight)
        panel.setFrame(bar, display: false)
        state.quickQuery = ""
        state.quickAttachments = []
        state.resetPromptNavigation()
        state.quickBarMode = true
        // Open empty chats in the background while you type, so Return is instant.
        WebManager.shared.prewarmNewChat()
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

    /// Opens the standard file picker and attaches the chosen files.
    func pickFiles() {
        let state = AppState.shared
        guard state.quickBarMode, !state.pickingFiles else { return }
        let picker = NSOpenPanel()
        picker.allowsMultipleSelection = true
        picker.canChooseDirectories = false
        picker.canChooseFiles = true
        picker.message = L("Velg filer å legge ved")
        picker.prompt = L("Legg ved")
        // Above the floating bar, so it isn't hidden behind it.
        picker.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)

        state.pickingFiles = true
        NSApp.activate(ignoringOtherApps: true)
        picker.begin { response in
            MainActor.assumeIsolated {
                state.pickingFiles = false
                if response == .OK { state.addAttachments(picker.urls) }
                self.panel.makeKeyAndOrderFront(nil)
                state.focusTick += 1
            }
        }
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
    /// With showHistory, the recent chats list opens once the window is in place.
    func expandFromBar(sending text: String?, newChat: Bool = true, showHistory: Bool = false) {
        let state = AppState.shared
        guard state.quickBarMode, let fullFrame = barFullFrame else { return }
        barFullFrame = nil
        let service = state.active
        let prompt = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        state.recordPrompt(prompt)
        state.resetPromptNavigation()

        panel.minSize = Self.normalMinSize
        let target = expandedFrame(size: fullFrame.size) ?? fullFrame
        morphBar(into: target)

        let files = newChat ? state.quickAttachments.map(\.url) : []
        state.quickAttachments = []
        if !prompt.isEmpty || !files.isEmpty {
            WebManager.shared.sendFromBar(prompt, files: files, in: service)
        } else if newChat {
            WebManager.shared.keepFreshChat(in: service)
        } else {
            WebManager.shared.undoPrewarm() // ⌘Return: back to the previous chat
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            WebManager.shared.focusInput(service)
            WebManager.shared.refreshTheme(service)
            if showHistory { state.showHistory = true }
        }
    }

    /// Puts the window back to its full size after hiding from the quick bar.
    private func leaveBarModeAfterHide() {
        let state = AppState.shared
        hostingView?.alphaValue = 1 // in case the window was hidden mid-animation
        guard state.quickBarMode else { return }
        state.quickBarMode = false
        state.quickAttachments = []
        WebManager.shared.undoPrewarm()
        panel.minSize = Self.normalMinSize
        if let fullFrame = barFullFrame { panel.setFrame(fullFrame, display: false) }
        barFullFrame = nil
        if collapsedFrame == nil { resumeFrameAutosave() }
    }

    func hide() {
        guard panel.isVisible else { return }
        morphWindow?.orderOut(nil)
        morphWindow = nil
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
        guard !AppState.shared.pinned, !AppState.shared.capturingScreenshot,
              !AppState.shared.pickingFiles else { return }
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
            resumeFrameAutosave()
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
                self.resumeFrameAutosave()
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

    /// Turns frame saving back on without moving the window. Setting the autosave name
    /// makes AppKit restore the last saved frame, so the current frame is saved first.
    /// (Without this, the window jumped back to its old spot after the bar expanded.)
    private func resumeFrameAutosave() {
        panel.saveFrame(usingName: "MiniChatPanel")
        panel.setFrameAutosaveName("MiniChatPanel")
    }

    /// A borderless overlay window used only during the bar-to-window animation.
    private var morphWindow: NSWindow?

    /// Grows the bar into the full window.
    ///
    /// Resizing the real window frame by frame stutters, because every step makes
    /// AppKit lay out the whole window, web page included. Instead, a lightweight
    /// rounded "ghost" in an overlay window is animated with a Core Animation spring
    /// (GPU-driven and synced to the display), while the real window is put at its
    /// final size, invisible, in one go. When the ghost lands, the window fades in on top.
    private func morphBar(into target: NSRect) {
        let state = AppState.shared
        let finish = {
            if self.collapsedFrame == nil { self.resumeFrameAutosave() }
            self.panel.invalidateShadow()
        }
        hostingView?.alphaValue = 1
        guard state.animations else {
            state.quickBarMode = false
            panel.setFrame(target, display: true)
            finish()
            return
        }

        let start = panel.frame
        // Room for the shadow, but kept on screen: macOS may move a window that sticks
        // out past the edge, which would shift the ghost away from where the window lands.
        var area = start.union(target).insetBy(dx: -60, dy: -60)
        if let screenFrame = (panel.screen ?? NSScreen.main)?.frame {
            area = area.intersection(screenFrame)
        }
        let overlay = NSWindow(contentRect: area, styleMask: .borderless, backing: .buffered, defer: false)
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.isReleasedWhenClosed = false
        overlay.level = panel.level
        overlay.collectionBehavior = panel.collectionBehavior
        let host = NSView(frame: NSRect(origin: .zero, size: area.size))
        host.wantsLayer = true
        overlay.contentView = host

        overlay.order(.above, relativeTo: panel.windowNumber)
        morphWindow = overlay
        // Measure from where the overlay actually ended up.
        let origin = overlay.frame.origin

        let ghost = CALayer()
        ghost.frame = start.offsetBy(dx: -origin.x, dy: -origin.y)
        ghost.cornerRadius = Self.cornerRadius
        ghost.cornerCurve = .continuous
        ghost.backgroundColor = Self.ghostColor()
        ghost.borderWidth = 0.5
        ghost.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        ghost.shadowColor = NSColor.black.cgColor
        ghost.shadowOpacity = 0.35
        ghost.shadowRadius = 18
        ghost.shadowOffset = CGSize(width: 0, height: -6)
        host.layer?.addSublayer(ghost)

        // The real window: hidden, swapped to the full chat and placed at its final size.
        panel.alphaValue = 0
        state.quickBarMode = false
        panel.setFrame(target, display: true)

        // A non-bouncy spring, like SwiftUI's default ".smooth" motion.
        let duration = 0.42
        // Aim for where the real window actually is (macOS may have adjusted the frame).
        let end = panel.frame.offsetBy(dx: -origin.x, dy: -origin.y)
        let moves: [(String, NSValue, NSValue)] = [
            ("position", NSValue(point: ghost.position), NSValue(point: CGPoint(x: end.midX, y: end.midY))),
            ("bounds", NSValue(rect: ghost.bounds), NSValue(rect: CGRect(origin: .zero, size: end.size))),
        ]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (keyPath, from, to) in moves {
            let spring = CASpringAnimation(perceptualDuration: duration, bounce: 0)
            spring.keyPath = keyPath
            spring.fromValue = from
            spring.toValue = to
            spring.duration = spring.settlingDuration
            ghost.add(spring, forKey: keyPath)
        }
        ghost.position = CGPoint(x: end.midX, y: end.midY)
        ghost.bounds = CGRect(origin: .zero, size: end.size)
        CATransaction.commit()

        // Hand over to the real window while the ghost is in its final, barely moving tail.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration * 0.8) {
            guard self.morphWindow === overlay else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.panel.animator().alphaValue = 1
                overlay.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    overlay.orderOut(nil)
                    if self.morphWindow === overlay { self.morphWindow = nil }
                    finish()
                }
            })
        }
    }

    /// The ghost's color: the page color the top bar uses, so the hand-over is seamless.
    private static func ghostColor() -> CGColor {
        let state = AppState.shared
        if state.matchPageColor, let color = state.themes[state.active]?.color {
            return NSColor(color).cgColor
        }
        // Resolve the system color for the current light/dark mode.
        var color = NSColor.black.cgColor
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor.windowBackgroundColor.cgColor
        }
        return color
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
