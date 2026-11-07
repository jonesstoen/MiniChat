import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A global keyboard shortcut: a key plus Carbon modifier flags.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    /// The key as shown to the user, for example "Space" or "K".
    var keyName: String

    static let defaultShortcut = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), keyName: "Space")

    var display: String { Self.symbols(for: modifiers) + keyName }

    /// The peek shortcut is the same shortcut with ⇧ added (none if it already uses ⇧).
    var peek: Shortcut? {
        guard modifiers & UInt32(shiftKey) == 0 else { return nil }
        return Shortcut(keyCode: keyCode, modifiers: modifiers | UInt32(shiftKey), keyName: keyName)
    }

    static func symbols(for modifiers: UInt32) -> String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text
    }

    /// Builds a shortcut from a key press, or nil if it has no ⌘, ⌥ or ⌃
    /// (a global shortcut without them would block normal typing).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        guard carbon != 0 else { return nil }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: carbon, keyName: Self.keyName(for: event))
    }

    init(keyCode: UInt32, modifiers: UInt32, keyName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyName = keyName
    }

    private static func keyName(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12:
            return fKeyName(Int(event.keyCode))
        default:
            return (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }

    private static func fKeyName(_ code: Int) -> String {
        let map = [kVK_F1: 1, kVK_F2: 2, kVK_F3: 3, kVK_F4: 4, kVK_F5: 5, kVK_F6: 6,
                   kVK_F7: 7, kVK_F8: 8, kVK_F9: 9, kVK_F10: 10, kVK_F11: 11, kVK_F12: 12]
        return "F\(map[code] ?? 0)"
    }
}

/// Owns the global hotkeys, so they can be changed while the app runs.
@MainActor
final class HotKeyController {
    static let shared = HotKeyController()

    private var main: HotKey?
    private var peek: HotKey?

    /// Registers the shortcut saved in the settings. Returns false if another app owns it.
    @discardableResult
    func register() -> Bool {
        main = nil
        peek = nil
        let shortcut = AppState.shared.shortcut
        main = HotKey(id: 1, keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) {
            PanelController.shared.toggle()
        }
        if let peekShortcut = shortcut.peek {
            peek = HotKey(id: 2, keyCode: peekShortcut.keyCode, modifiers: peekShortcut.modifiers) {
                PanelController.shared.togglePeek()
            }
        }
        AppState.shared.hotKeyFailed = main == nil
        return main != nil
    }

    /// Turned off while a new shortcut is being recorded, so pressing the old one
    /// doesn't toggle the window.
    func suspend() {
        main = nil
        peek = nil
    }
}

/// A button that records a new shortcut when clicked.
@MainActor
struct ShortcutRecorder: View {
    @Bindable var state: AppState
    @State private var recording = false
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    recording ? stop() : start()
                } label: {
                    Text(recording ? L("Trykk en tastekombinasjon …") : state.shortcut.display)
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .frame(minWidth: 120)
                }
                if state.shortcut != .defaultShortcut && !recording {
                    Button(L("Tilbakestill")) {
                        state.shortcut = .defaultShortcut
                        message = HotKeyController.shared.register() ? nil : L("Den er allerede i bruk av en annen app.")
                    }
                }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        message = nil
        HotKeyController.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
                return nil
            }
            guard let shortcut = Shortcut(event: event) else {
                message = L("Bruk minst én av ⌘, ⌥ eller ⌃.")
                return nil
            }
            let previous = state.shortcut
            state.shortcut = shortcut
            if HotKeyController.shared.register() {
                message = nil
            } else {
                message = L("Den er allerede i bruk av en annen app.")
                state.shortcut = previous
                HotKeyController.shared.register()
            }
            stop(reregister: false)
            return nil
        }
    }

    private func stop(reregister: Bool = true) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording && reregister { HotKeyController.shared.register() }
        recording = false
    }
}
