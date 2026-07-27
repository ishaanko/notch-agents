import Foundation

struct UsageWindow: Identifiable, Equatable, Sendable {
    var id: String
    var agent: AgentKind
    var windowLabel: String
    var remainingPercent: Int
    var resetsAt: Date?

    /// Compatibility for existing views. Usage meters now represent capacity
    /// remaining, so an API value of 19% used is rendered as 81% left.
    var usedPercent: Int { remainingPercent }
    var remainingLabel: String { "\(remainingPercent)% left" }

    init(
        id: String,
        agent: AgentKind,
        windowLabel: String,
        usedPercent: Double,
        resetsAt: Date?
    ) {
        self.id = id
        self.agent = agent
        self.windowLabel = windowLabel
        remainingPercent = Self.remainingPercent(fromUsed: usedPercent)
        self.resetsAt = resetsAt
    }

    static func remainingPercent(fromUsed usedPercent: Double) -> Int {
        min(100, max(0, Int((100 - usedPercent).rounded())))
    }

    var resetLabel: String {
        guard let resetsAt else { return "" }
        let remaining = max(0, Int(resetsAt.timeIntervalSinceNow))
        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        if days > 0 { return "\(days)d\(hours)h" }
        let minutes = (remaining % 3_600) / 60
        return hours > 0 ? "\(hours)h\(minutes)m" : "\(minutes)m"
    }
}

enum UsageDisplayPreferences {
    static let selectedProviderKey = "notchAgents.selectedUsageProvider"
    static let pinnedWindowIDsKey = "notchAgents.pinnedUsageWindows"

    static func pinnedWindowIDs(from rawValue: String) -> [String] {
        var seen: Set<String> = []
        return rawValue
            .split(separator: ",")
            .map(String.init)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func rawValue(for ids: [String]) -> String {
        ids.joined(separator: ",")
    }

    static func displayedWindows(
        from windows: [UsageWindow],
        selectedProviderID: String,
        pinnedWindowIDs: [String]
    ) -> [UsageWindow] {
        guard !windows.isEmpty else { return [] }
        let availableProviders = windows.map(\.agent.rawValue)
        let selected = availableProviders.contains(selectedProviderID)
            ? selectedProviderID
            : availableProviders[0]
        let pinned = Set(pinnedWindowIDs)
        var seen: Set<String> = []
        return windows.filter {
            (pinned.contains($0.id) || $0.agent.rawValue == selected)
                && seen.insert($0.id).inserted
        }
    }
}

@MainActor
final class UsageMonitor: ObservableObject {
    @Published private(set) var windows: [UsageWindow] = []
    private var timer: Timer?
    private var refreshTask: Task<Void, Never>?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 60
    }

    func refresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { Self.readCodexUsage() }.value
            guard let self else { return }
            defer { self.refreshTask = nil }
            guard !Task.isCancelled else { return }
            if self.windows != result {
                self.windows = result
            }
        }
    }

    func ingest(_ payload: [String: Any]) {
        let source = (payload["source"] as? String) ?? (payload["agent"] as? String)
        let agent = AgentKind.parse(source)
        let limits = payload["rate_limits"] as? [String: Any] ?? payload
        guard let used = (limits["used_percent"] as? NSNumber)?.doubleValue,
              let minutes = (limits["window_minutes"] as? NSNumber)?.intValue else { return }
        let resetSeconds = (limits["resets_at"] as? NSNumber)?.doubleValue
        let reset = resetSeconds.map(Date.init(timeIntervalSince1970:))
        let label = minutes >= 1_440 ? "\(minutes / 1_440)d" : (minutes >= 60 ? "\(minutes / 60)h" : "\(minutes)m")
        let entry = UsageWindow(
            id: "\(agent.rawValue)-\(minutes)",
            agent: agent,
            windowLabel: label,
            usedPercent: used,
            resetsAt: reset
        )
        windows.removeAll { $0.id == entry.id }
        windows.append(entry)
    }

    nonisolated private static func readCodexUsage() -> [UsageWindow] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        var files: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            files.append((url, date))
        }
        files.sort { $0.1 > $1.1 }

        for (url, _) in files.prefix(16) {
            guard let data = readTail(url, bytes: 768 * 1_024), let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").reversed() {
                guard line.contains("\"rate_limits\""),
                      let data = String(line).data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = root["payload"] as? [String: Any],
                      let limits = payload["rate_limits"] as? [String: Any],
                      (limits["limit_id"] as? String) == "codex" else { continue }
                var result: [UsageWindow] = []
                if let primary = limits["primary"] as? [String: Any] {
                    result.append(makeWindow(primary, id: "codex-primary"))
                }
                if let secondary = limits["secondary"] as? [String: Any] {
                    result.append(makeWindow(secondary, id: "codex-secondary"))
                }
                if !result.isEmpty { return result }
            }
        }
        return []
    }

    nonisolated private static func makeWindow(_ value: [String: Any], id: String) -> UsageWindow {
        let minutes = (value["window_minutes"] as? NSNumber)?.intValue ?? 0
        let label: String
        if minutes >= 1_440 { label = "\(minutes / 1_440)d" }
        else if minutes >= 60 { label = "\(minutes / 60)h" }
        else { label = "\(minutes)m" }
        let percent = (value["used_percent"] as? NSNumber)?.doubleValue ?? 0
        let resetSeconds = (value["resets_at"] as? NSNumber)?.doubleValue
        return UsageWindow(id: id, agent: .codex, windowLabel: label, usedPercent: percent, resetsAt: resetSeconds.map(Date.init(timeIntervalSince1970:)))
    }

    nonisolated static func readTail(_ url: URL, bytes: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: end > bytes ? end - bytes : 0)
        return try? handle.readToEnd()
    }
}
