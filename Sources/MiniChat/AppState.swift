import SwiftUI
import UniformTypeIdentifiers
import AppKit
import Observation

enum Service: String, CaseIterable, Identifiable, Codable {
    case chatgpt, claude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chatgpt: return "ChatGPT"
        case .claude: return "Claude"
        }
    }

    /// Color of the dot in the service switcher.
    var color: Color {
        switch self {
        case .chatgpt: return Color(red: 0.06, green: 0.64, blue: 0.50)
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
        }
    }

    /// URL for a new, empty chat.
    var homeURL: URL {
        switch self {
        case .chatgpt: return URL(string: "https://chatgpt.com/")!
        case .claude: return URL(string: "https://claude.ai/new")!
        }
    }
}

/// A chat in the history or bookmarks.
struct ChatEntry: Codable, Identifiable, Hashable {
    var url: String
    var service: Service
    var title: String
    var customTitle: String?
    var bookmarked: Bool
    var lastVisited: Date

    var id: String { url }
    var displayTitle: String { customTitle ?? title }
}

/// Background color of the page, so the top bar can match it.
struct PageTheme: Equatable {
    let color: Color
    let isDark: Bool
}

@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    var active: Service = Service(rawValue: UserDefaults.standard.string(forKey: "service") ?? "") ?? .chatgpt {
        didSet { UserDefaults.standard.set(active.rawValue, forKey: "service") }
    }
    var hotKeyFailed = false
    /// Page colors, remembered between launches so the top bar and the quick bar
    /// animation have the right color from the start.
    var themes: [Service: PageTheme] = AppState.loadThemes()

    nonisolated private static func loadThemes() -> [Service: PageTheme] {
        guard let saved = UserDefaults.standard.dictionary(forKey: "pageColors") as? [String: [Double]] else { return [:] }
        var themes: [Service: PageTheme] = [:]
        for (key, rgb) in saved where rgb.count == 3 {
            guard let service = Service(rawValue: key) else { continue }
            themes[service] = makeTheme(red: rgb[0], green: rgb[1], blue: rgb[2])
        }
        return themes
    }

    nonisolated static func makeTheme(red: Double, green: Double, blue: Double) -> PageTheme {
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return PageTheme(color: Color(.sRGB, red: red, green: green, blue: blue, opacity: 1), isDark: luminance < 0.5)
    }

    /// Whether the service is currently writing an answer.
    var busy: [Service: Bool] = [:]
    /// Answers that finished while the window was hidden.
    var unseenCount = 0
    /// Toggles every half second while an answer is being written (drives the pulse).
    var pulse = false
    var isExpanded = false
    var focusMode = UserDefaults.standard.bool(forKey: "focusMode") {
        didSet { UserDefaults.standard.set(focusMode, forKey: "focusMode") }
    }
    var headerRevealed = false
    var showHistory = false
    var showStats = false
    var showPalette = false
    var paletteQuery = ""
    var paletteIndex = 0
    var pinned: Bool = (UserDefaults.standard.object(forKey: "pinned") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(pinned, forKey: "pinned") }
    }
    var history: [ChatEntry] = AppState.loadHistory()

    /// Quick bar: a small input line shown instead of the full window after a break.
    var quickBarMode = false
    var quickQuery = ""
    /// Bumped to move keyboard focus into the quick bar.
    var focusTick = 0
    var quickAttachments: [QuickAttachment] = []
    /// True while something is dragged over the quick bar.
    var dropTargeted = false
    /// True while the screenshot tool is open, so the window doesn't auto-hide.
    @ObservationIgnored var capturingScreenshot = false
    /// True while the file picker is open, so the window doesn't auto-hide.
    @ObservationIgnored var pickingFiles = false
    /// Minutes without the window open before ⌥Space shows the quick bar (0 = off).
    var idleResetMinutes: Int = (UserDefaults.standard.object(forKey: "idleResetMinutes") as? Int) ?? 60 {
        didSet { UserDefaults.standard.set(idleResetMinutes, forKey: "idleResetMinutes") }
    }
    @ObservationIgnored var lastHidden: Date? = UserDefaults.standard.object(forKey: "lastHidden") as? Date {
        didSet { UserDefaults.standard.set(lastHidden, forKey: "lastHidden") }
    }

    var quickBarDue: Bool {
        guard idleResetMinutes > 0 else { return false }
        guard let lastHidden else { return true }
        return Date().timeIntervalSince(lastHidden) >= Double(idleResetMinutes) * 60
    }

    enum ExpandSide: String, CaseIterable {
        case right, left, lastPosition
    }

    /// Where the full window opens when the quick bar expands.
    var expandSide: ExpandSide = ExpandSide(rawValue: UserDefaults.standard.string(forKey: "expandSide") ?? "") ?? .right {
        didSet { UserDefaults.standard.set(expandSide.rawValue, forKey: "expandSide") }
    }

    /// The global shortcut that shows and hides the window.
    var shortcut: Shortcut = AppState.loadShortcut() {
        didSet {
            if let data = try? JSONEncoder().encode(shortcut) {
                UserDefaults.standard.set(data, forKey: "shortcut")
            }
        }
    }

    nonisolated private static func loadShortcut() -> Shortcut {
        guard let data = UserDefaults.standard.data(forKey: "shortcut"),
              let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data) else { return .defaultShortcut }
        return shortcut
    }

    // MARK: Quick bar question history (↑ / ↓)

    @ObservationIgnored private var promptHistory: [String] =
        UserDefaults.standard.stringArray(forKey: "promptHistory") ?? []
    @ObservationIgnored private var historyIndex: Int?
    @ObservationIgnored private var historyDraft = ""

    func recordPrompt(_ prompt: String) {
        guard rememberHistory, !prompt.isEmpty else { return }
        promptHistory.removeAll { $0 == prompt }
        promptHistory.append(prompt)
        if promptHistory.count > 50 { promptHistory.removeFirst(promptHistory.count - 50) }
        UserDefaults.standard.set(promptHistory, forKey: "promptHistory")
    }

    func resetPromptNavigation() {
        historyIndex = nil
        historyDraft = ""
    }

    /// ↑ goes to older questions, ↓ to newer, and past the newest back to what you were typing.
    func navigatePrompts(older: Bool) {
        guard !promptHistory.isEmpty else { return }
        if older {
            if let index = historyIndex {
                historyIndex = max(0, index - 1)
            } else {
                historyDraft = quickQuery
                historyIndex = promptHistory.count - 1
            }
        } else {
            guard let index = historyIndex else { return }
            if index + 1 < promptHistory.count {
                historyIndex = index + 1
            } else {
                historyIndex = nil
                quickQuery = historyDraft
                return
            }
        }
        if let index = historyIndex { quickQuery = promptHistory[index] }
    }

    /// Privacy: puts a neutral cover over the chat.
    var contentHidden = false
    /// When the service started the answer it is currently writing.
    var busySince: [Service: Date] = [:]

    // MARK: Settings (stored in UserDefaults)

    var notifyWhenDone: Bool = AppState.flag("notifyWhenDone", true) {
        didSet { UserDefaults.standard.set(notifyWhenDone, forKey: "notifyWhenDone") }
    }
    var dockBadge: Bool = AppState.flag("dockBadge", true) {
        didSet {
            UserDefaults.standard.set(dockBadge, forKey: "dockBadge")
            if !dockBadge { NSApp.dockTile.badgeLabel = nil }
        }
    }
    var soundEnabled: Bool = AppState.flag("soundEnabled", false) {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: "soundEnabled") }
    }
    var soundName: String = UserDefaults.standard.string(forKey: "soundName") ?? "Glass" {
        didSet { UserDefaults.standard.set(soundName, forKey: "soundName") }
    }
    var menuPulse: Bool = AppState.flag("menuPulse", true) {
        didSet { UserDefaults.standard.set(menuPulse, forKey: "menuPulse") }
    }
    var showTimer: Bool = AppState.flag("showTimer", true) {
        didSet { UserDefaults.standard.set(showTimer, forKey: "showTimer") }
    }
    var animations: Bool = AppState.flag("animations", true) {
        didSet { UserDefaults.standard.set(animations, forKey: "animations") }
    }
    var matchPageColor: Bool = AppState.flag("matchPageColor", true) {
        didSet {
            UserDefaults.standard.set(matchPageColor, forKey: "matchPageColor")
            applyAppearance()
        }
    }
    var showInDock: Bool = AppState.flag("showInDock", true) {
        didSet {
            UserDefaults.standard.set(showInDock, forKey: "showInDock")
            applyDockVisibility()
        }
    }
    /// Same key as @AppStorage in MiniChatApp, so the menu bar icon follows along.
    var showInMenuBar: Bool = AppState.flag("showInMenuBar", true) {
        didSet { UserDefaults.standard.set(showInMenuBar, forKey: "showInMenuBar") }
    }
    var rememberHistory: Bool = AppState.flag("rememberHistory", true) {
        didSet { UserDefaults.standard.set(rememberHistory, forKey: "rememberHistory") }
    }
    var collectStats: Bool = AppState.flag("collectStats", true) {
        didSet { UserDefaults.standard.set(collectStats, forKey: "collectStats") }
    }

    nonisolated static func flag(_ key: String, _ fallback: Bool) -> Bool {
        (UserDefaults.standard.object(forKey: key) as? Bool) ?? fallback
    }

    static let soundNames = ["Glass", "Ping", "Pop", "Tink", "Hero", "Purr", "Submarine", "Funk"]

    func playDoneSound() {
        NSSound(named: NSSound.Name(soundName))?.play()
    }

    func applyDockVisibility() {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    func toggleContentHidden() {
        withAnimation(.easeInOut(duration: 0.15)) { contentHidden.toggle() }
        if contentHidden {
            PanelController.shared.clearWebFocus()
        } else {
            WebManager.shared.focusInput(active)
        }
    }

    func clearHistory() {
        history.removeAll { !$0.bookmarked }
        saveHistory()
        promptHistory = []
        UserDefaults.standard.removeObject(forKey: "promptHistory")
    }

    var bookmarks: [ChatEntry] {
        history.filter(\.bookmarked).sorted { $0.displayTitle.localizedCompare($1.displayTitle) == .orderedAscending }
    }

    var recents: [ChatEntry] {
        history.filter { !$0.bookmarked }.sorted { $0.lastVisited > $1.lastVisited }
    }

    @ObservationIgnored private var pulseTimer: Timer?

    var anyBusy: Bool { busy.values.contains(true) }

    // MARK: Answer finished

    func setBusy(_ isBusy: Bool, for service: Service) {
        let wasBusy = busy[service] ?? false
        guard wasBusy != isBusy else { return }
        busy[service] = isBusy
        busySince[service] = isBusy ? Date() : nil
        updatePulse()
        if wasBusy && !isBusy { answerFinished(service) }
    }

    private func answerFinished(_ service: Service) {
        UsageTracker.shared.recordAnswer(service)
        if soundEnabled { playDoneSound() }
        let seen = PanelController.shared.isShowing && active == service
        guard !seen else { return }
        unseenCount += 1
        if dockBadge { NSApp.dockTile.badgeLabel = "\(unseenCount)" }
        if notifyWhenDone { Notifier.post(service: service) }
    }

    func markSeen() {
        unseenCount = 0
        NSApp.dockTile.badgeLabel = nil
    }

    private func updatePulse() {
        if anyBusy, pulseTimer == nil {
            pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                MainActor.assumeIsolated { AppState.shared.pulse.toggle() }
            }
        } else if !anyBusy {
            pulseTimer?.invalidate()
            pulseTimer = nil
            pulse = false
        }
    }

    // MARK: Focus mode

    func toggleFocusMode() {
        withAnimation(.easeInOut(duration: 0.2)) {
            focusMode.toggle()
            headerRevealed = false
        }
        PanelController.shared.updateHoverTracking()
    }

    func setHeaderRevealed(_ revealed: Bool) {
        guard headerRevealed != revealed else { return }
        withAnimation(.easeOut(duration: 0.18)) { headerRevealed = revealed }
    }

    func switchTo(_ service: Service) {
        if service != active {
            UsageTracker.shared.recordSwitch()
            UsageTracker.shared.update(visible: PanelController.shared.isShowing, service: service)
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            active = service
        }
        applyAppearance()
        // Wait until the view has swapped pages before moving focus.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // In the quick bar, keep typing in the bar instead of the page.
            if !AppState.shared.quickBarMode { WebManager.shared.focusInput(service) }
            WebManager.shared.refreshTheme(service)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            WebManager.shared.refreshTheme(service)
        }
    }

    // MARK: Quick bar attachments

    func addAttachments(_ urls: [URL], copy: Bool = true) {
        for url in urls where url.isFileURL {
            guard quickAttachments.count < AttachmentStore.maxCount else { break }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            let stored = copy ? (AttachmentStore.copy(url) ?? url) : url
            quickAttachments.append(QuickAttachment(url: stored, isImage: AttachmentStore.isImage(stored)))
            NSLog("Mini Chat: attached %@", stored.lastPathComponent)
        }
        PanelController.shared.updateBarHeight()
    }

    /// Handles a drop on the quick bar. A file URL is used directly; anything else that
    /// is an image (for example the floating screenshot thumbnail) is saved as a file.
    func attach(from providers: [NSItemProvider]) {
        NSLog("Mini Chat: dropped %ld item(s)", providers.count)
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    Task { @MainActor in AppState.shared.addAttachments([url]) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                    // The file is deleted when this handler returns, so copy it right away.
                    guard let url, let copy = AttachmentStore.copy(url) else { return }
                    Task { @MainActor in AppState.shared.addAttachments([copy], copy: false) }
                }
            }
        }
        focusTick += 1
    }

    func removeAttachment(_ attachment: QuickAttachment) {
        quickAttachments.removeAll { $0.id == attachment.id }
        PanelController.shared.updateBarHeight()
    }

    /// ⌘V in the quick bar: attaches copied files or images. Returns false when
    /// the clipboard holds text, so it is pasted into the text field as usual.
    func attachFromPasteboard() -> Bool {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            addAttachments(urls)
            return true
        }
        if pasteboard.string(forType: .string) == nil,
           let image = NSImage(pasteboard: pasteboard),
           let url = AttachmentStore.save(image) {
            addAttachments([url], copy: false)
            return true
        }
        return false
    }

    func toggleService() {
        switchTo(active == .chatgpt ? .claude : .chatgpt)
    }

    func setTheme(red: Double, green: Double, blue: Double, for service: Service) {
        let theme = Self.makeTheme(red: red, green: green, blue: blue)
        if themes[service] != theme {
            withAnimation(.easeInOut(duration: 0.25)) { themes[service] = theme }
            var saved = UserDefaults.standard.dictionary(forKey: "pageColors") as? [String: [Double]] ?? [:]
            saved[service.rawValue] = [red, green, blue]
            UserDefaults.standard.set(saved, forKey: "pageColors")
        }
        if service == active { applyAppearance() }
    }

    /// The window always follows the system appearance. Only the top bar adapts
    /// to the page (see HeaderBar). Forcing an appearance on the window would also
    /// change the pages' prefers-color-scheme and could get stuck in light mode.
    func applyAppearance() {
        PanelController.shared.setSystemAppearance()
    }

    // MARK: Pin

    func togglePinned() {
        pinned.toggle()
    }

    // MARK: History and bookmarks

    private static let maxRecents = 30

    /// Returns a stable URL for the chat, or nil if the page is not a chat.
    nonisolated static func conversationKey(for service: Service, url: URL) -> String? {
        guard let host = url.host else { return nil }
        let path = url.path
        switch service {
        case .chatgpt:
            guard host.hasSuffix("chatgpt.com"), path.contains("/c/") else { return nil }
            return "https://chatgpt.com" + path
        case .claude:
            guard host.hasSuffix("claude.ai"), path.hasPrefix("/chat/") else { return nil }
            return "https://claude.ai" + path
        }
    }

    nonisolated static func cleanTitle(_ raw: String?) -> String? {
        guard var title = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        for suffix in [" - Claude", " | Claude", " – Claude", " - ChatGPT", " | ChatGPT", " – ChatGPT"] where title.hasSuffix(suffix) {
            title = String(title.dropLast(suffix.count))
        }
        let generic = ["chatgpt", "claude", "new chat", "ny samtale", "ny chat"]
        return generic.contains(title.lowercased()) ? nil : title
    }

    func recordVisit(service: Service, url: URL, title: String?) {
        guard rememberHistory else { return }
        guard let key = Self.conversationKey(for: service, url: url) else { return }
        let clean = Self.cleanTitle(title)
        if let index = history.firstIndex(where: { $0.url == key }) {
            history[index].lastVisited = Date()
            if let clean { history[index].title = clean }
        } else {
            history.insert(ChatEntry(
                url: key, service: service, title: clean ?? L("Uten tittel"),
                customTitle: nil, bookmarked: false, lastVisited: Date()
            ), at: 0)
        }
        prune()
        saveHistory()
    }

    func open(_ entry: ChatEntry) {
        showHistory = false
        if active != entry.service { switchTo(entry.service) }
        WebManager.shared.load(entry.url, in: entry.service)
    }

    func toggleBookmark(_ entry: ChatEntry) {
        guard let index = history.firstIndex(where: { $0.id == entry.id }) else { return }
        history[index].bookmarked.toggle()
        prune()
        saveHistory()
    }

    /// Bookmarks (or unbookmarks) the current chat.
    func toggleBookmarkCurrent() {
        let webView = WebManager.shared.webView(for: active)
        guard let url = webView.url, let key = Self.conversationKey(for: active, url: url) else {
            NSSound.beep()
            return
        }
        recordVisit(service: active, url: url, title: webView.title)
        if let entry = history.first(where: { $0.url == key }) { toggleBookmark(entry) }
    }

    var currentIsBookmarked: Bool {
        guard let url = WebManager.shared.webView(for: active).url,
              let key = Self.conversationKey(for: active, url: url) else { return false }
        return history.first { $0.url == key }?.bookmarked ?? false
    }

    func rename(_ entry: ChatEntry) {
        let alert = NSAlert()
        alert.messageText = L("Gi samtalen et nytt navn")
        alert.addButton(withTitle: L("Lagre"))
        alert.addButton(withTitle: L("Avbryt"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = entry.displayTitle
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn,
              let index = history.firstIndex(where: { $0.id == entry.id }) else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        history[index].customTitle = name.isEmpty ? nil : name
        saveHistory()
    }

    func remove(_ entry: ChatEntry) {
        history.removeAll { $0.id == entry.id }
        saveHistory()
    }

    private func prune() {
        let keep = Set(recents.prefix(Self.maxRecents).map(\.id))
        history.removeAll { !$0.bookmarked && !keep.contains($0.id) }
    }

    func saveHistory() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(history) {
            UserDefaults.standard.set(data, forKey: "history")
        }
    }

    nonisolated private static func loadHistory() -> [ChatEntry] {
        guard let data = UserDefaults.standard.data(forKey: "history") else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ChatEntry].self, from: data)) ?? []
    }
}
