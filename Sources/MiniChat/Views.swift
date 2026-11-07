import SwiftUI
import AppKit
import WebKit

@MainActor
struct RootView: View {
    let state: AppState

    var body: some View {
        if state.quickBarMode {
            ZStack {
                // Keep the pages in the window (invisible) so the fresh chat loads at full
                // speed while you type. Pages outside the window are slowed down by WebKit.
                WebContainer(service: state.active)
                    .opacity(0)
                    .allowsHitTesting(false)
                QuickBarView(state: state)
            }
            .ignoresSafeArea()
        } else {
            fullWindow
        }
    }

    private var fullWindow: some View {
        VStack(spacing: 0) {
            if !state.focusMode {
                HeaderBar(state: state)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if state.hotKeyFailed {
                Text(LF("%@ er allerede i bruk av en annen app (for eksempel den gamle ChatGPT-appen). Velg en annen hurtigtast i innstillingene, eller avslutt den andre appen og start Mini Chat på nytt.", state.shortcut.display))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            WebContainer(service: state.active)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if state.contentHidden { PrivacyCover(state: state) }
                }
                .overlay(alignment: .bottomTrailing) {
                    ResizeHandle().frame(width: 16, height: 16)
                }
        }
        // Focus mode: the top bar slides in over the page when the mouse is at the top edge.
        .overlay(alignment: .top) {
            if state.focusMode && state.headerRevealed {
                HeaderBar(state: state)
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // Command palette (⌘J)
        .overlay(alignment: .top) {
            if state.showPalette {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.25)
                        .onTapGesture { state.closePalette() }
                    CommandPalette(state: state)
                        .padding(.horizontal, 16)
                        .padding(.top, 56)
                        .frame(maxWidth: 480)
                }
                .transition(.opacity)
            }
        }
        .sheet(isPresented: Binding(get: { state.showStats }, set: { state.showStats = $0 })) {
            UsageView(usage: UsageTracker.shared) { state.showStats = false }
        }
        .ignoresSafeArea()
        .frame(minWidth: 360, minHeight: 320)
    }
}

// MARK: - Quick bar

/// Small input line shown after a break. Return sends and grows into the full window.
@MainActor
struct QuickBarView: View {
    @Bindable var state: AppState
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !state.quickAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(state.quickAttachments) { attachment in
                            AttachmentChip(attachment: attachment) { state.removeAttachment(attachment) }
                        }
                    }
                    .padding(.top, 10)
                }
                .padding(.horizontal, 14)
            }
            inputRow
                .frame(height: 64)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(DragHandle())
        // Drops are received by DropEffectView (AppKit), see Panel.swift.
        .overlay {
            if state.dropTargeted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(2)
            }
        }
        .onAppear { focused = true }
        .onChange(of: state.focusTick) { focused = true }
    }

    private var inputRow: some View {
        HStack(spacing: 12) {
            Button {
                state.toggleService()
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(state.active.color).frame(width: 8, height: 8)
                    Text(state.active.title).font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(L("Bytt tjeneste (Tab)"))

            TextField(LF("Spør %@ …", state.active.title), text: $state.quickQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .focused($focused)
                .onSubmit { PanelController.shared.expandFromBar(sending: state.quickQuery) }

            HeaderIcon("paperclip", help: "Legg ved filer (⌘O)") {
                PanelController.shared.pickFiles()
            }

            HeaderIcon("camera.viewfinder", help: "Ta skjermbilde (⌘⇧S)") {
                PanelController.shared.captureScreenshot()
            }

            // No question, just looking for an old chat: open the window with the recent list.
            HeaderIcon("clock.arrow.circlepath", help: "Åpne vinduet med nylige samtaler") {
                PanelController.shared.expandFromBar(sending: nil, newChat: false, showHistory: true)
            }

            Image(systemName: "return")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
    }
}

/// Thumbnail of an attached file, with a button to remove it.
@MainActor
struct AttachmentChip: View {
    let attachment: QuickAttachment
    let onRemove: () -> Void

    var body: some View {
        Image(nsImage: AttachmentStore.thumbnail(for: attachment))
            .resizable()
            .aspectRatio(contentMode: attachment.isImage ? .fill : .fit)
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
            .overlay(alignment: .topTrailing) {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: -5)
            }
            .padding(.top, 4)
            .padding(.trailing, 4)
            .help(attachment.name)
    }
}

// MARK: - Top bar

@MainActor
struct HeaderBar: View {
    let state: AppState
    @Environment(\.colorScheme) private var systemScheme

    private var headerScheme: ColorScheme {
        guard state.matchPageColor, let theme = state.themes[state.active] else { return systemScheme }
        return theme.isDark ? .dark : .light
    }

    var body: some View {
        HStack(spacing: 2) {
            ServiceSwitcher(state: state)
            Spacer(minLength: 8)
            HeaderIcon("square.and.pencil", help: "Ny samtale (⌘N)") {
                WebManager.shared.newChat(state.active)
            }
            HeaderIcon("clock.arrow.circlepath", help: "Nylige samtaler og bokmerker (⌘Y)") {
                state.showHistory.toggle()
            }
            .popover(isPresented: Binding(
                get: { state.showHistory },
                set: { state.showHistory = $0 }
            ), arrowEdge: .bottom) {
                HistoryPopover(state: state)
            }
            HeaderIcon(
                state.pinned ? "pin.fill" : "pin",
                help: state.pinned ? "Festet: ligger alltid øverst (⌘P)" : "Ikke festet: skjules når du klikker utenfor (⌘P)",
                active: state.pinned
            ) {
                state.togglePinned()
            }
            HeaderIcon(
                state.isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                help: state.isExpanded ? "Gjør mindre (⌘E)" : "Utvid (⌘E)"
            ) {
                PanelController.shared.toggleExpanded()
            }
            MoreMenu(state: state)
            HeaderIcon("xmark", help: "Skjul (Esc)") {
                PanelController.shared.hide()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 46)
        // Light or dark icons and text depending on the page color under the bar.
        .environment(\.colorScheme, headerScheme)
        .background {
            ZStack {
                // Same color as the page, so the window reads as one surface.
                if state.matchPageColor, let color = state.themes[state.active]?.color {
                    color
                } else if state.focusMode {
                    Rectangle().fill(.regularMaterial)
                } else {
                    Color.clear
                }
                DragHandle()
            }
        }
    }
}

/// Capsule switcher with a colored dot and a marker that slides between options.
@MainActor
struct ServiceSwitcher: View {
    let state: AppState
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Service.allCases) { service in
                let selected = state.active == service
                let busy = state.busy[service] ?? false
                Button {
                    state.switchTo(service)
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(service.color)
                            .frame(width: 7, height: 7)
                            .opacity(busy ? (state.pulse ? 1 : 0.3) : (selected ? 1 : 0.45))
                            .scaleEffect(busy && state.pulse ? 1.25 : 1)
                            .animation(.easeInOut(duration: 0.45), value: state.pulse)
                        Text(service.title)
                            .font(.system(size: 12, weight: .semibold))
                        if busy, state.showTimer, let start = state.busySince[service] {
                            // Reads state.pulse so the text refreshes every half second.
                            let _ = state.pulse
                            let seconds = Int(Date().timeIntervalSince(start))
                            Text("\(seconds) s")
                                .font(.system(size: 10, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .background {
                        if selected {
                            Capsule()
                                .fill(Color.primary.opacity(0.12))
                                .matchedGeometryEffect(id: "pill", in: namespace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .help("Bytt tjeneste (⌘1 / ⌘2 eller Ctrl+Tab)")
    }
}

/// Neutral cover over the chat, for screen sharing and meetings.
@MainActor
struct PrivacyCover: View {
    let state: AppState

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            VStack(spacing: 10) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Samtalen er skjult")
                    .font(.headline)
                Button("Vis samtalen") { state.toggleContentHidden() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Text("⌘⇧H")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .transition(.opacity)
    }
}

/// List of bookmarked and recent chats.
@MainActor
struct HistoryPopover: View {
    let state: AppState
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private func matches(_ entry: ChatEntry) -> Bool {
        query.split(separator: " ").allSatisfy { entry.displayTitle.localizedStandardContains($0) }
    }

    var body: some View {
        let bookmarks = state.bookmarks.filter { matches($0) }
        let recents = state.recents.filter { matches($0) }
        let isEmpty = state.history.isEmpty

        VStack(spacing: 0) {
            if !isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Søk i samtaler", text: $query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onSubmit {
                            if let first = (bookmarks + recents).first { state.open(first) }
                        }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                Divider()
            }

            if isEmpty {
                Text("Ingen samtaler ennå.\nSamtalene du åpner dukker opp her.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(24)
                    .frame(width: 300)
            } else if bookmarks.isEmpty && recents.isEmpty {
                Text("Ingen treff")
                    .foregroundStyle(.secondary)
                    .frame(width: 320, height: 120)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if !bookmarks.isEmpty {
                            sectionHeader("Bokmerker")
                            ForEach(bookmarks) { HistoryRow(entry: $0, state: state) }
                        }
                        if !recents.isEmpty {
                            sectionHeader("Nylige")
                            ForEach(recents) { HistoryRow(entry: $0, state: state) }
                        }
                    }
                    .padding(8)
                }
                .frame(width: 320, height: 360)
            }
        }
        .onAppear { searchFocused = true }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(L(title).uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}

@MainActor
struct HistoryRow: View {
    let entry: ChatEntry
    let state: AppState
    @State private var hovering = false

    var body: some View {
        Button {
            state.open(entry)
        } label: {
            HStack(spacing: 10) {
                Circle().fill(entry.service.color).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.displayTitle)
                        .lineLimit(1)
                    Text(entry.lastVisited, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if entry.bookmarked {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(L(entry.bookmarked ? "Fjern bokmerke" : "Bokmerk")) { state.toggleBookmark(entry) }
            Button("Gi nytt navn …") { state.rename(entry) }
            Divider()
            Button("Fjern fra listen", role: .destructive) { state.remove(entry) }
        }
    }
}

/// "More" menu with options that don't need their own button.
@MainActor
struct MoreMenu: View {
    let state: AppState
    @State private var hovering = false

    var body: some View {
        Menu {
            Button(L(state.isExpanded ? "Gjør mindre   ⌘E" : "Utvid   ⌘E")) { PanelController.shared.toggleExpanded() }
            Button("Fest til venstre kant   ⌃⌥←") { PanelController.shared.snap(.left) }
            Button("Fest til høyre kant   ⌃⌥→") { PanelController.shared.snap(.right) }
            Button("Midt på skjermen   ⌃⌥↑") { PanelController.shared.snap(.center) }
            Divider()
            Button(L(state.currentIsBookmarked ? "Fjern bokmerke   ⌘D" : "Bokmerk samtalen   ⌘D")) {
                state.toggleBookmarkCurrent()
            }
            Divider()
            Button("Kommandomeny   ⌘J") { state.togglePalette() }
            Button(L(state.contentHidden ? "Vis samtalen   ⌘⇧H" : "Skjul samtalen   ⌘⇧H")) { state.toggleContentHidden() }
            Button("Statistikk") { state.showStats = true }
            Button("Åpne Nedlastinger") { WebManager.shared.openDownloadsFolder() }
            Divider()
            Button("Last inn på nytt   ⌘R") { WebManager.shared.reload(state.active) }
            Button("Åpne i nettleseren") { WebManager.shared.openInBrowser(state.active) }
            Divider()
            Button(L(state.focusMode ? "Slå av fokusmodus   ⌘⇧F" : "Fokusmodus   ⌘⇧F")) {
                state.toggleFocusMode()
            }
            Divider()
            Button("Innstillinger …   ⌘,") { SettingsWindowController.shared.show() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .foregroundStyle(hovering ? Color.primary : Color.secondary.opacity(0.8))
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Mer")
        .onHover { isHovering in
            withAnimation(.easeOut(duration: 0.12)) { hovering = isHovering }
        }
    }
}

/// Icon button that is dimmed by default and lights up on hover.
@MainActor
struct HeaderIcon: View {
    private let systemName: String
    private let help: String
    private let action: () -> Void
    private let active: Bool
    @State private var hovering = false

    init(_ systemName: String, help: String, active: Bool = false, action: @escaping () -> Void) {
        self.systemName = systemName
        self.help = help
        self.active = active
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .foregroundStyle(hovering || active ? Color.primary : Color.secondary.opacity(0.8))
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(L(help))
        .onHover { isHovering in
            withAnimation(.easeOut(duration: 0.12)) { hovering = isHovering }
        }
    }
}

// MARK: - AppKit bridges

struct DragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragHandleView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct ResizeHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ResizeHandleView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Shows the right WKWebView. Both web views stay attached to the window, with the
/// active one on top. A web view that is removed from the window gets throttled by
/// WebKit, which stalls an answer that is still being written in the other tab.
struct WebContainer: NSViewRepresentable {
    let service: Service

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ container: NSView, context: Context) {
        MainActor.assumeIsolated {
            let manager = WebManager.shared
            // Attach both, inactive first so the active one ends up on top.
            let order = Service.allCases.filter { $0 != service } + [service]
            for item in order {
                let webView = manager.webView(for: item)
                if webView.superview !== container {
                    webView.removeFromSuperview()
                    webView.translatesAutoresizingMaskIntoConstraints = true
                    webView.autoresizingMask = [.width, .height]
                    webView.frame = container.bounds
                    container.addSubview(webView)
                }
            }
            let active = manager.webView(for: service)
            if container.subviews.last !== active {
                container.addSubview(active, positioned: .above, relativeTo: nil)
                active.frame = container.bounds
            }
        }
    }
}
