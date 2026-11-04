import SwiftUI
import AppKit
import ServiceManagement

/// Separate settings window (⌘,).
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(state: AppState.shared))
            let window = NSWindow(contentViewController: hosting)
            window.title = L("Mini Chat – innstillinger")
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
struct SettingsView: View {
    @Bindable var state: AppState
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings(state: state)
                .tabItem { Label("Generelt", systemImage: "gearshape") }
                .tag(0)
            NotificationSettings(state: state)
                .tabItem { Label("Varsler", systemImage: "bell") }
                .tag(1)
            PrivacySettings(state: state)
                .tabItem { Label("Personvern", systemImage: "hand.raised") }
                .tag(2)
            ShortcutList()
                .tabItem { Label("Snarveier", systemImage: "keyboard") }
                .tag(3)
        }
        .frame(width: 480, height: 540)
        .padding(.top, 8)
    }
}

// MARK: - General

@MainActor
struct GeneralSettings: View {
    @Bindable var state: AppState
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Oppstart") {
                Toggle("Start ved innlogging", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Toggle("Vis i Dock", isOn: $state.showInDock)
                    .disabled(state.showInDock && !state.showInMenuBar)
                Toggle("Vis i menylinjen", isOn: $state.showInMenuBar)
                    .disabled(state.showInMenuBar && !state.showInDock)
                Text("Minst én av dem må være på, så du alltid finner appen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Vindu") {
                Toggle("Nål: ligg alltid øverst", isOn: $state.pinned)
                Text("Når nålen er av, skjules vinduet når du klikker i en annen app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Fokusmodus (skjul toppen)", isOn: Binding(
                    get: { state.focusMode },
                    set: { if $0 != state.focusMode { state.toggleFocusMode() } }
                ))
                Picker("Søkelinje etter pause", selection: $state.idleResetMinutes) {
                    Text("Av").tag(0)
                    Text("15 min").tag(15)
                    Text("30 min").tag(30)
                    Text("1 time").tag(60)
                    Text("2 timer").tag(120)
                }
                Text("Etter en pause åpner ⌥Space en liten søkelinje for et nytt spørsmål i stedet for den forrige samtalen. ⌘Return i linjen åpner den forrige samtalen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Animasjoner", isOn: $state.animations)
                Toggle("Toppen får samme farge som nettsiden", isOn: $state.matchPageColor)
            }

            Section("Tjeneste ved oppstart") {
                Picker("Åpne i", selection: Binding(
                    get: { state.active },
                    set: { state.switchTo($0) }
                )) {
                    ForEach(Service.allCases) { Text($0.title).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Notifications

@MainActor
struct NotificationSettings: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Section("Når et svar er ferdig") {
                Toggle("Vis varsel (når vinduet er skjult)", isOn: $state.notifyWhenDone)
                Toggle("Tall på Dock-ikonet", isOn: $state.dockBadge)
                    .disabled(!state.showInDock)
                Toggle("Spill av lyd", isOn: $state.soundEnabled)
                HStack {
                    Picker("Lyd", selection: $state.soundName) {
                        ForEach(AppState.soundNames, id: \.self) { Text($0).tag($0) }
                    }
                    Button("Test") { state.playDoneSound() }
                }
                .disabled(!state.soundEnabled)
            }

            Section("Mens et svar skrives") {
                Toggle("Pulserende ikon i menylinjen", isOn: $state.menuPulse)
                Toggle("Vis tidtaker i bryteren", isOn: $state.showTimer)
            }

            Section {
                Button("Åpne varselinnstillinger i macOS") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } footer: {
                Text("Hvis varsler ikke dukker opp, sjekk at Mini Chat har lov til å vise varsler i macOS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Privacy

@MainActor
struct PrivacySettings: View {
    @Bindable var state: AppState
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section("Skjul samtalen") {
                Toggle("Samtalen er skjult nå", isOn: Binding(
                    get: { state.contentHidden },
                    set: { if $0 != state.contentHidden { state.toggleContentHidden() } }
                ))
                Text("Trykk ⌘⇧H i vinduet for å skjule eller vise samtalen raskt, for eksempel når du deler skjerm.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Historikk") {
                Toggle("Husk nylige samtaler", isOn: $state.rememberHistory)
                Button("Tøm nylige samtaler") { confirmClear = true }
                    .confirmationDialog("Tømme listen over nylige samtaler?", isPresented: $confirmClear) {
                        Button("Tøm", role: .destructive) { state.clearHistory() }
                    } message: {
                        Text("Bokmerker beholdes. Samtalene selv slettes ikke hos ChatGPT eller Claude.")
                    }
            }

            Section("Statistikk") {
                Toggle("Samle bruksstatistikk", isOn: $state.collectStats)
                HStack {
                    Button("Vis statistikk") {
                        state.showStats = true
                        PanelController.shared.show(full: true)
                    }
                    Button("Nullstill") { UsageTracker.shared.reset() }
                }
                Text("Historikk og statistikk lagres bare på denne Macen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcuts

private struct ShortcutGroup: Identifiable {
    let title: String
    let items: [ShortcutItem]
    var id: String { title }
}

private struct ShortcutItem: Identifiable {
    let keys: String
    let action: String
    var id: String { keys + action }
}

struct ShortcutList: View {
    private let groups: [ShortcutGroup] = [
        ShortcutGroup(title: "Overalt", items: [
            ShortcutItem(keys: "⌥Space", action: "Vis / skjul vinduet"),
            ShortcutItem(keys: "⌥⇧Space", action: "Kikk: vis uten å ta tastaturet"),
        ]),
        ShortcutGroup(title: "I vinduet", items: [
            ShortcutItem(keys: "Tab", action: "Søkelinjen: bytt tjeneste"),
            ShortcutItem(keys: "⌘↩", action: "Søkelinjen: åpne forrige samtale"),
            ShortcutItem(keys: "⌘V", action: "Søkelinjen: legg ved fil eller bilde"),
            ShortcutItem(keys: "⌘⇧S", action: "Søkelinjen: ta skjermbilde"),
            ShortcutItem(keys: "⌘J", action: "Kommandomeny"),
            ShortcutItem(keys: "⌘1 / ⌘2", action: "ChatGPT / Claude"),
            ShortcutItem(keys: "Ctrl+Tab", action: "Bytt tjeneste"),
            ShortcutItem(keys: "⌘N", action: "Ny samtale"),
            ShortcutItem(keys: "⌘Y", action: "Nylige samtaler og bokmerker"),
            ShortcutItem(keys: "⌘D", action: "Bokmerk samtalen"),
            ShortcutItem(keys: "⌘E / dobbeltklikk toppen", action: "Utvid / gjør mindre"),
            ShortcutItem(keys: "⌃⌥← / ⌃⌥→ / ⌃⌥↑", action: "Fest til venstre / høyre / midten"),
            ShortcutItem(keys: "⌘P", action: "Nål av / på"),
            ShortcutItem(keys: "⌘⇧F", action: "Fokusmodus"),
            ShortcutItem(keys: "⌘⇧H", action: "Skjul / vis samtalen"),
            ShortcutItem(keys: "⌘R", action: "Last inn på nytt"),
            ShortcutItem(keys: "⌘[ / ⌘]", action: "Tilbake / frem"),
            ShortcutItem(keys: "⌘,", action: "Innstillinger"),
            ShortcutItem(keys: "Esc / ⌘W", action: "Skjul vinduet"),
        ]),
    ]

    var body: some View {
        Form {
            ForEach(groups) { group in
                Section(L(group.title)) {
                    ForEach(group.items) { item in
                        HStack {
                            Text(L(item.action))
                            Spacer()
                            Text(L(item.keys))
                                .font(.system(.body, design: .rounded).weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
