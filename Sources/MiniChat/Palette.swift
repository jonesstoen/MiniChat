import SwiftUI
import AppKit

/// A single command in the command palette (⌘J).
struct PaletteCommand: Identifiable {
    let id: String
    let title: String
    let detail: String?
    let icon: String
    var tint: Color? = nil
    let action: @MainActor () -> Void
}

extension AppState {
    /// All commands, plus bookmarks and recent chats.
    var paletteCommands: [PaletteCommand] {
        let panel = PanelController.shared
        let web = WebManager.shared
        var list: [PaletteCommand] = [
            PaletteCommand(id: "new", title: LF("Ny samtale i %@", active.title), detail: "⌘N", icon: "square.and.pencil") {
                web.newChat(AppState.shared.active)
            },
            PaletteCommand(id: "chatgpt", title: L("Bytt til ChatGPT"), detail: "⌘1", icon: "circle.fill", tint: Service.chatgpt.color) {
                AppState.shared.switchTo(.chatgpt)
            },
            PaletteCommand(id: "claude", title: L("Bytt til Claude"), detail: "⌘2", icon: "circle.fill", tint: Service.claude.color) {
                AppState.shared.switchTo(.claude)
            },
            PaletteCommand(id: "history", title: L("Nylige samtaler og bokmerker"), detail: "⌘Y", icon: "clock.arrow.circlepath") {
                let state = AppState.shared
                if state.focusMode { state.setHeaderRevealed(true) }
                state.showHistory = true
            },
            PaletteCommand(id: "bookmark", title: L(currentIsBookmarked ? "Fjern bokmerke" : "Bokmerk samtalen"), detail: "⌘D", icon: "star") {
                AppState.shared.toggleBookmarkCurrent()
            },
            PaletteCommand(id: "expand", title: L(isExpanded ? "Gjør vinduet mindre" : "Utvid vinduet"), detail: "⌘E", icon: "arrow.up.left.and.arrow.down.right") {
                panel.toggleExpanded()
            },
            PaletteCommand(id: "left", title: L("Fest til venstre kant"), detail: "⌃⌥←", icon: "rectangle.lefthalf.filled") {
                panel.snap(.left)
            },
            PaletteCommand(id: "right", title: L("Fest til høyre kant"), detail: "⌃⌥→", icon: "rectangle.righthalf.filled") {
                panel.snap(.right)
            },
            PaletteCommand(id: "center", title: L("Midt på skjermen"), detail: "⌃⌥↑", icon: "rectangle.center.inset.filled") {
                panel.snap(.center)
            },
            PaletteCommand(id: "pin", title: L(pinned ? "Løsne nålen (skjul ved klikk utenfor)" : "Fest med nål (alltid øverst)"), detail: "⌘P", icon: pinned ? "pin.slash" : "pin") {
                AppState.shared.togglePinned()
            },
            PaletteCommand(id: "focus", title: L(focusMode ? "Slå av fokusmodus" : "Fokusmodus"), detail: "⌘⇧F", icon: "rectangle.dashed") {
                AppState.shared.toggleFocusMode()
            },
            PaletteCommand(id: "reload", title: L("Last inn på nytt"), detail: "⌘R", icon: "arrow.clockwise") {
                web.reload(AppState.shared.active)
            },
            PaletteCommand(id: "browser", title: L("Åpne i nettleseren"), detail: nil, icon: "safari") {
                web.openInBrowser(AppState.shared.active)
            },
            PaletteCommand(id: "downloads", title: L("Åpne Nedlastinger"), detail: nil, icon: "arrow.down.circle") {
                web.openDownloadsFolder()
            },
            PaletteCommand(id: "stats", title: L("Statistikk"), detail: nil, icon: "chart.bar") {
                AppState.shared.showStats = true
            },
            PaletteCommand(id: "privacy", title: L(contentHidden ? "Vis samtalen" : "Skjul samtalen"), detail: "⌘⇧H", icon: "eye.slash") {
                AppState.shared.toggleContentHidden()
            },
            PaletteCommand(id: "settings", title: L("Innstillinger"), detail: "⌘,", icon: "gearshape") {
                SettingsWindowController.shared.show()
            },
        ]

        for entry in bookmarks + recents {
            list.append(PaletteCommand(
                id: "open-" + entry.id,
                title: entry.displayTitle,
                detail: L(entry.bookmarked ? "Bokmerke" : "Nylig"),
                icon: entry.bookmarked ? "star.fill" : "bubble.left",
                tint: entry.service.color
            ) {
                AppState.shared.open(entry)
            })
        }
        return list
    }

    var filteredPaletteCommands: [PaletteCommand] {
        let words = paletteQuery.split(separator: " ").map(String.init)
        let all = paletteCommands
        guard !words.isEmpty else { return Array(all.prefix(15)) }
        return all.filter { command in
            words.allSatisfy { command.title.localizedStandardContains($0) }
        }
    }

    func togglePalette() {
        if showPalette {
            closePalette()
        } else {
            paletteQuery = ""
            paletteIndex = 0
            showHistory = false
            withAnimation(.easeOut(duration: 0.15)) { showPalette = true }
        }
    }

    func closePalette(refocus: Bool = true) {
        withAnimation(.easeIn(duration: 0.12)) { showPalette = false }
        if refocus {
            let service = active
            DispatchQueue.main.async { WebManager.shared.focusInput(service) }
        }
    }

    func movePaletteSelection(_ delta: Int) {
        let count = filteredPaletteCommands.count
        guard count > 0 else { return }
        paletteIndex = (paletteIndex + delta + count) % count
    }

    func runPaletteSelection() {
        let commands = filteredPaletteCommands
        guard commands.indices.contains(paletteIndex) else { return }
        run(commands[paletteIndex])
    }

    func run(_ command: PaletteCommand) {
        closePalette(refocus: false)
        // Run after the palette has closed, so popovers and sheets appear correctly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            command.action()
            if !AppState.shared.showHistory && !AppState.shared.showStats {
                WebManager.shared.focusInput(AppState.shared.active)
            }
        }
    }
}

@MainActor
struct CommandPalette: View {
    @Bindable var state: AppState
    @FocusState private var focused: Bool

    var body: some View {
        let commands = state.filteredPaletteCommands
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Skriv en kommando eller søk i samtaler", text: $state.paletteQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit { state.runPaletteSelection() }
                    .onChange(of: state.paletteQuery) { state.paletteIndex = 0 }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            if commands.isEmpty {
                Text("Ingen treff")
                    .foregroundStyle(.secondary)
                    .padding(20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                                PaletteRow(command: command, selected: index == state.paletteIndex)
                                    .id(command.id)
                                    .onTapGesture { state.run(command) }
                                    .onHover { if $0 { state.paletteIndex = index } }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: state.paletteIndex) {
                        if commands.indices.contains(state.paletteIndex) {
                            proxy.scrollTo(commands[state.paletteIndex].id)
                        }
                    }
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .onAppear { focused = true }
    }
}

@MainActor
struct PaletteRow: View {
    let command: PaletteCommand
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: command.icon)
                .font(.system(size: command.icon == "circle.fill" ? 8 : 13))
                .foregroundStyle(command.tint ?? Color.secondary)
                .frame(width: 20)
            Text(command.title).lineLimit(1)
            Spacer(minLength: 8)
            if let detail = command.detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.25) : .clear))
        .contentShape(Rectangle())
    }
}
