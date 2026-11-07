import SwiftUI
import AppKit
import Carbon.HIToolbox
import ServiceManagement

@main
struct MiniChatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("showInMenuBar") private var showInMenuBar = true

    var body: some Scene {
        MenuBarExtra(isInserted: $showInMenuBar) {
            MenuContent()
        } label: {
            MenuBarIcon(state: AppState.shared)
        }
    }
}

/// Menu bar icon: pulses while an answer is being written and shows a checkmark
/// when an answer finished while the window was hidden.
@MainActor
struct MenuBarIcon: View {
    let state: AppState

    var body: some View {
        Image(systemName: symbol)
    }

    private var symbol: String {
        guard state.menuPulse else { return "bubble.left.and.bubble.right" }
        if state.anyBusy { return state.pulse ? "ellipsis.bubble.fill" : "ellipsis.bubble" }
        if state.unseenCount > 0 { return "checkmark.bubble.fill" }
        return "bubble.left.and.bubble.right"
    }
}

@MainActor
struct MenuContent: View {
    var body: some View {
        Button("Vis Mini Chat   \(AppState.shared.shortcut.display)") { PanelController.shared.show() }
        let bookmarks = AppState.shared.bookmarks
        if !bookmarks.isEmpty {
            Menu("Bokmerker") {
                ForEach(bookmarks) { entry in
                    Button(entry.displayTitle) {
                        AppState.shared.open(entry)
                        PanelController.shared.show(full: true)
                    }
                }
            }
        }
        Divider()
        ForEach(Service.allCases) { service in
            Button("Åpne \(service.title)") {
                AppState.shared.switchTo(service)
                PanelController.shared.show()
            }
        }
        Divider()
        Button("Innstillinger …") { SettingsWindowController.shared.show() }
            .keyboardShortcut(",")
        Button("Avslutt Mini Chat") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppState.shared.applyDockVisibility()
        Notifier.setup()

        // Load both services in the background so switching is instant.
        for service in Service.allCases {
            _ = WebManager.shared.webView(for: service)
        }

        // The shortcut (⌥Space by default) and its peek variant with ⇧ added.
        let registered = HotKeyController.shared.register()

        let firstLaunch = !UserDefaults.standard.bool(forKey: "launchedBefore")
        UserDefaults.standard.set(true, forKey: "launchedBefore")
        if firstLaunch || !registered {
            PanelController.shared.show(full: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        UsageTracker.shared.update(visible: false, service: AppState.shared.active)
    }

    /// Clicking the Dock icon shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        PanelController.shared.show()
        return false
    }

    /// Keep the app running when the window is hidden.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
