import SwiftUI

/// Usage statistics per day. Stored only on this Mac.
struct DayUsage: Codable, Equatable {
    var opens = 0
    var switches = 0
    var seconds: [String: Double] = [:]
    var answers: [String: Int] = [:]
}

@MainActor
@Observable
final class UsageTracker {
    static let shared = UsageTracker()

    private(set) var days: [String: DayUsage] = UsageTracker.load()
    @ObservationIgnored private var segmentStart: Date?
    @ObservationIgnored private var segmentService: Service?

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func key(for date: Date) -> String { formatter.string(from: date) }

    // MARK: Recording

    /// Called when the window is shown or hidden, or the service changes.
    func update(visible: Bool, service: Service) {
        closeSegment()
        if visible {
            segmentStart = Date()
            segmentService = service
        }
    }

    func recordOpen() {
        modifyToday { $0.opens += 1 }
    }

    func recordSwitch() {
        modifyToday { $0.switches += 1 }
    }

    func recordAnswer(_ service: Service) {
        modifyToday { $0.answers[service.rawValue, default: 0] += 1 }
    }

    /// Adds the time since the last update (also used before the app quits).
    func flush() {
        guard let service = segmentService else { return }
        closeSegment()
        segmentStart = Date()
        segmentService = service
    }

    private func closeSegment() {
        defer { segmentStart = nil; segmentService = nil }
        guard let start = segmentStart, let service = segmentService else { return }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0, elapsed < 12 * 3600 else { return }
        modifyToday { $0.seconds[service.rawValue, default: 0] += elapsed }
    }

    private func modifyToday(_ change: (inout DayUsage) -> Void) {
        guard AppState.flag("collectStats", true) else { return }
        let today = Self.key(for: Date())
        var usage = days[today] ?? DayUsage()
        change(&usage)
        days[today] = usage
        save()
    }

    // MARK: Computed values

    var today: DayUsage { days[Self.key(for: Date())] ?? DayUsage() }

    var total: DayUsage {
        days.values.reduce(into: DayUsage()) { sum, day in
            sum.opens += day.opens
            sum.switches += day.switches
            for (k, v) in day.seconds { sum.seconds[k, default: 0] += v }
            for (k, v) in day.answers { sum.answers[k, default: 0] += v }
        }
    }

    var lastSevenDays: [(label: String, seconds: Double)] {
        let calendar = Calendar.current
        let weekday = DateFormatter()
        weekday.locale = appLocale
        weekday.dateFormat = "EEEEE"
        return (0..<7).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()) else { return nil }
            let day = days[Self.key(for: date)] ?? DayUsage()
            return (weekday.string(from: date).uppercased(), day.seconds.values.reduce(0, +))
        }
    }

    /// Number of consecutive days (up to today or yesterday) with usage.
    var streak: Int {
        let calendar = Calendar.current
        var count = 0
        var date = Date()
        if (days[Self.key(for: date)]?.opens ?? 0) == 0 {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: date) else { return 0 }
            date = yesterday
        }
        while (days[Self.key(for: date)]?.opens ?? 0) > 0 {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: date) else { break }
            date = previous
        }
        return count
    }

    func reset() {
        days = [:]
        save()
    }

    // MARK: Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(days) {
            UserDefaults.standard.set(data, forKey: "usage")
        }
    }

    nonisolated private static func load() -> [String: DayUsage] {
        guard let data = UserDefaults.standard.data(forKey: "usage"),
              let days = try? JSONDecoder().decode([String: DayUsage].self, from: data) else { return [:] }
        return days
    }
}

// MARK: - View

@MainActor
struct UsageView: View {
    let usage: UsageTracker
    let onClose: () -> Void
    @State private var showTotal = false

    var body: some View {
        let stats = showTotal ? usage.total : usage.today
        let gpt = stats.seconds[Service.chatgpt.rawValue] ?? 0
        let claude = stats.seconds[Service.claude.rawValue] ?? 0
        let totalTime = gpt + claude

        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Statistikk").font(.title3.weight(.semibold))
                Spacer()
                Picker("", selection: $showTotal) {
                    Text("I dag").tag(false)
                    Text("Totalt").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
            }

            // Split between the services
            VStack(alignment: .leading, spacing: 6) {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        if totalTime > 0 {
                            Capsule().fill(Service.chatgpt.color)
                                .frame(width: max(4, geo.size.width * gpt / totalTime))
                            Capsule().fill(Service.claude.color)
                        } else {
                            Capsule().fill(Color.primary.opacity(0.1))
                        }
                    }
                }
                .frame(height: 10)

                HStack {
                    legend(.chatgpt, seconds: gpt, share: totalTime > 0 ? gpt / totalTime : 0)
                    Spacer()
                    legend(.claude, seconds: claude, share: totalTime > 0 ? claude / totalTime : 0)
                }
                Text(verdict(gpt: gpt, claude: claude))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            // Numbers
            HStack(spacing: 10) {
                tile("\(stats.opens)", L("ganger åpnet"))
                tile("\(stats.answers.values.reduce(0, +))", L("svar mottatt"))
                tile("\(stats.switches)", L("bytter"))
            }

            // Last 7 days
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Siste 7 dager").font(.headline)
                    Spacer()
                    if usage.streak > 1 {
                        Text("🔥 \(usage.streak) dager på rad").font(.callout).foregroundStyle(.secondary)
                    }
                }
                let week = usage.lastSevenDays
                let maxSeconds = max(week.map(\.seconds).max() ?? 0, 60)
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(Array(week.enumerated()), id: \.offset) { item in
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(item.offset == week.count - 1 ? Color.accentColor : Color.primary.opacity(0.25))
                                .frame(height: max(3, 60 * item.element.seconds / maxSeconds))
                            Text(item.element.label).font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .help(Self.duration(item.element.seconds))
                    }
                }
                .frame(height: 80, alignment: .bottom)
            }

            HStack {
                Button("Nullstill") { usage.reset() }
                Spacer()
                Button("Lukk", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func legend(_ service: Service, seconds: Double, share: Double) -> some View {
        HStack(spacing: 6) {
            Circle().fill(service.color).frame(width: 8, height: 8)
            Text("\(service.title) \(Self.duration(seconds))")
                .font(.callout)
            Text("\(Int((share * 100).rounded())) %")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
    }

    private func verdict(gpt: Double, claude: Double) -> String {
        let total = gpt + claude
        guard total > 60 else { return L("For lite data ennå. Prat litt mer!") }
        let share = claude / total
        switch share {
        case ..<0.2: return L("Du er et ChatGPT-menneske.")
        case ..<0.4: return L("Du heller mot ChatGPT.")
        case ..<0.6: return L("Helt nøytral. Diplomatisk!")
        case ..<0.8: return L("Du heller mot Claude.")
        default: return L("Du er et Claude-menneske.")
        }
    }

    static func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return L("under 1 min") }
        if minutes < 60 { return LF("%d min", minutes) }
        return LF("%d t %d min", minutes / 60, minutes % 60)
    }
}
