import Foundation

struct DiscoveredSession: Equatable, Sendable {
    var id: String
    var projectName: String
    var conversationTitle: String
    var activity: LiveActivity
    var capabilities: ProviderCapabilities
    var cwd: String?
    var updatedAt: Date
    var status: SessionStatus
    var threadID: String
    var rolloutPath: String?
    var model: String?
    var reasoningEffort: String?
    var interaction: AgentInteraction? = nil
}

struct CodexRolloutUpdate: Sendable {
    var activity: LiveActivity
    var interaction: AgentInteraction?
}

enum CodexRolloutParser {
    /// Consumes complete JSONL records, retaining an incomplete final record in `buffer`.
    static func consume(buffer: inout Data) -> [LiveActivity] {
        consumeUpdates(buffer: &buffer).map(\.activity)
    }

    static func consumeUpdates(buffer: inout Data) -> [CodexRolloutUpdate] {
        var updates: [CodexRolloutUpdate] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let root = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let update = update(from: root) else { continue }
            updates.append(update)
        }
        return updates
    }

    static func activity(from root: [String: Any], now: Date = Date()) -> LiveActivity? {
        update(from: root, now: now)?.activity
    }

    static func update(from root: [String: Any], now: Date = Date()) -> CodexRolloutUpdate? {
        let envelopeType = root["type"] as? String
        guard envelopeType != "response_item" || !containsEncryptedOnly(root) else { return nil }
        let payload = root["payload"] as? [String: Any] ?? root
        let type = (payload["type"] as? String ?? envelopeType ?? "").lowercased()
        let timestamp = eventDate(root: root, payload: payload) ?? now
        let activity: LiveActivity

        switch type {
        case "agent_reasoning":
            guard let text = clean(payload["text"] as? String), !text.isEmpty else { return nil }
            activity = LiveActivity(phase: .thinking, text: text, toolName: nil, updatedAt: timestamp, isLive: true)
        case "custom_tool_call", "function_call":
            let name = clean((payload["name"] ?? payload["tool_name"]) as? String) ?? "tool"
            activity = LiveActivity(phase: .tool, text: "Using \(name)", toolName: name, updatedAt: timestamp, isLive: true)
        case "mcp_tool_call_begin", "mcp_tool_call_end", "web_search_begin", "web_search_end":
            let name = clean((payload["tool"] ?? payload["name"] ?? payload["server"]) as? String) ?? "connected tool"
            activity = LiveActivity(phase: .tool, text: "Using \(name)", toolName: name, updatedAt: timestamp, isLive: true)
        case "patch_apply_begin":
            activity = LiveActivity(phase: .editing, text: "Applying changes", toolName: "apply_patch", updatedAt: timestamp, isLive: true)
        case "patch_apply_end":
            let success = (payload["success"] as? Bool) ?? true
            let count = (payload["changes"] as? [String: Any])?.count ?? 0
            let text = success ? (count > 0 ? "Updated \(count) file\(count == 1 ? "" : "s")" : "Changes applied") : "Couldn’t apply changes"
            activity = LiveActivity(phase: success ? .editing : .failed, text: text, toolName: "apply_patch", updatedAt: timestamp, isLive: false)
        case "task_started", "turn_started":
            activity = LiveActivity(phase: .working, text: "Starting work…", toolName: nil, updatedAt: timestamp, isLive: true)
        case "task_complete", "turn_complete", "completed":
            activity = LiveActivity(phase: .succeeded, text: clean(payload["message"] as? String) ?? "Completed", toolName: nil, updatedAt: timestamp, isLive: false)
        case "turn_aborted", "task_failed", "error":
            activity = LiveActivity(phase: .failed, text: clean((payload["message"] ?? payload["error"]) as? String) ?? "Task failed", toolName: nil, updatedAt: timestamp, isLive: false)
        case "agent_message":
            guard let message = clean(payload["message"] as? String) else { return nil }
            activity = LiveActivity(phase: .waiting, text: message, toolName: nil, updatedAt: timestamp, isLive: false)
        case "custom_tool_call_output", "function_call_output":
            activity = LiveActivity(phase: .thinking, text: "Reviewing tool result…", toolName: nil, updatedAt: timestamp, isLive: true)
        case "request_user_input", "elicitation_request":
            let prompt = clean((payload["prompt"] ?? payload["message"]) as? String) ?? "Codex needs your input"
            // Rollout files are passive observations. The connected hook or app
            // transport owns interactive requests; the observer must not create
            // a form it cannot answer.
            activity = LiveActivity(
                phase: .waiting,
                text: prompt,
                toolName: nil,
                updatedAt: timestamp,
                isLive: false
            )
        case "exec_approval_request", "apply_patch_approval_request", "request_permissions":
            let prompt = clean((payload["reason"] ?? payload["message"]) as? String) ?? "Codex needs approval"
            activity = LiveActivity(
                phase: .waiting,
                text: prompt,
                toolName: nil,
                updatedAt: timestamp,
                isLive: false
            )
        default:
            return nil
        }
        return CodexRolloutUpdate(activity: activity, interaction: nil)
    }

    private static func containsEncryptedOnly(_ root: [String: Any]) -> Bool {
        guard let payload = root["payload"] as? [String: Any] else { return false }
        return payload["encrypted_content"] != nil && payload["text"] == nil && payload["message"] == nil
    }

    private static func eventDate(root: [String: Any], payload: [String: Any]) -> Date? {
        let raw = (root["timestamp"] ?? payload["timestamp"] ?? root["created_at"] ?? payload["created_at"])
        if let seconds = raw as? Double {
            return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1_000 : seconds)
        }
        if let seconds = raw as? Int {
            let value = Double(seconds)
            return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1_000 : value)
        }
        guard let value = raw as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let compact = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty, !compact.hasPrefix("<environment_context>") else { return nil }
        return String(compact.prefix(260))
    }
}

@MainActor
final class CodexSessionWatcher {
    private var timer: Timer?
    private var scanTask: Task<Void, Never>?
    private let onSessions: ([DiscoveredSession]) -> Void
    private var fileWatchers: [String: CodexRolloutFileWatcher] = [:]
    private var metadata: [String: DiscoveredSession] = [:]
    private var lastDiscovery: [DiscoveredSession] = []

    init(onSessions: @escaping ([DiscoveredSession]) -> Void) {
        self.onSessions = onSessions
    }

    func start() {
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        timer?.tolerance = 15
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        scanTask?.cancel()
        scanTask = nil
        fileWatchers.values.forEach { $0.stop() }
        fileWatchers.removeAll()
    }

    private func scan() {
        guard scanTask == nil else { return }
        scanTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { Self.discover() }.value
            guard let self else { return }
            defer { self.scanTask = nil }
            guard !Task.isCancelled, result != self.lastDiscovery else { return }
            self.lastDiscovery = result
            self.metadata = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
            self.onSessions(result)
            self.syncWatchers(with: result)
        }
    }

    private func syncWatchers(with sessions: [DiscoveredSession]) {
        let active = Dictionary(uniqueKeysWithValues: sessions.compactMap { item -> (String, URL)? in
            guard let path = item.rolloutPath, !path.isEmpty else { return nil }
            return (item.id, URL(fileURLWithPath: path))
        })
        for key in fileWatchers.keys where active[key] == nil {
            fileWatchers.removeValue(forKey: key)?.stop()
        }
        for (id, url) in active {
            if fileWatchers[id]?.url == url { continue }
            fileWatchers.removeValue(forKey: id)?.stop()
            let watcher = CodexRolloutFileWatcher(url: url) { [weak self] update in
                Task { @MainActor in self?.publish(update, sessionID: id) }
            }
            fileWatchers[id] = watcher
            watcher.start()
        }
    }

    private func publish(_ update: CodexRolloutUpdate, sessionID: String) {
        guard var item = metadata[sessionID] else { return }
        item.activity = update.activity
        item.status = SessionStatus(phase: update.activity.phase)
        item.updatedAt = update.activity.updatedAt
        item.interaction = update.interaction
        metadata[sessionID] = item
        onSessions([item])
    }

    nonisolated private static func discover() -> [DiscoveredSession] {
        let database = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/state_5.sqlite")
        if let sessions = discoverFromDatabase(database), !sessions.isEmpty { return sessions }
        return discoverFromRolloutDirectory()
    }

    nonisolated static func discoverFromDatabase(_ database: URL) -> [DiscoveredSession]? {
        guard FileManager.default.fileExists(atPath: database.path) else { return nil }
        let query = """
        SELECT id,
               substr(replace(replace(rollout_path, char(9), ' '), char(10), ' '), 1, 2048),
               substr(replace(replace(COALESCE(NULLIF(name,''), NULLIF(title,''), NULLIF(first_user_message,''), 'Untitled'), char(9), ' '), char(10), ' '), 1, 180),
               substr(replace(cwd, char(9), ' '), 1, 1024),
               updated_at_ms,
               COALESCE(model, ''),
               COALESCE(reasoning_effort, ''),
               COALESCE(recency_at_ms, updated_at_ms)
        FROM threads
        WHERE archived = 0
          AND COALESCE(thread_source, '') <> 'subagent'
        ORDER BY recency_at_ms DESC
        LIMIT 10;
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-separator", "\t", database.path, query]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else { return nil }

        return output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 8,
                  let milliseconds = Double(fields[4]),
                  let recencyMilliseconds = Double(fields[7]) else { return nil }
            let updated = Date(timeIntervalSince1970: milliseconds / 1_000)
            let recency = Date(timeIntervalSince1970: recencyMilliseconds / 1_000)
            let age = -updated.timeIntervalSinceNow
            let phase: ActivityPhase = age < 20 ? .working : (age < 900 ? .waiting : .idle)
            let latest = latestUpdate(at: fields[1])
            let activity = latest?.activity ?? LiveActivity(
                phase: phase,
                text: phase == .working ? "Working…" : (phase == .waiting ? "Waiting for the next turn" : "Idle"),
                toolName: nil,
                updatedAt: updated,
                isLive: phase == .working
            )
            return DiscoveredSession(
                id: fields[0],
                projectName: URL(fileURLWithPath: fields[3]).lastPathComponent,
                conversationTitle: String(fields[2].prefix(120)),
                activity: activity,
                capabilities: ProviderCapabilities(liveActivity: true, eventActivity: true, approvals: true, questions: true, jumpToSession: true),
                cwd: fields[3],
                updatedAt: max(recency, activity.updatedAt),
                status: SessionStatus(phase: activity.phase),
                threadID: fields[0],
                rolloutPath: fields[1],
                model: fields[5].isEmpty ? nil : fields[5],
                reasoningEffort: fields[6].isEmpty ? nil : fields[6],
                interaction: latest?.interaction
            )
        }
    }

    nonisolated private static func discoverFromRolloutDirectory() -> [DiscoveredSession] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if date.timeIntervalSinceNow > -7_200 { files.append((url, date)) }
        }
        files.sort { $0.1 > $1.1 }
        return files.prefix(10).compactMap(parseFallback)
    }

    nonisolated private static func parseFallback(_ item: (URL, Date)) -> DiscoveredSession? {
        let (url, modified) = item
        guard let startData = try? Data(contentsOf: url, options: .mappedIfSafe),
              let firstLine = String(data: startData.prefix(256 * 1_024), encoding: .utf8)?.split(separator: "\n").first,
              let firstJSON = try? JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any],
              let meta = firstJSON["payload"] as? [String: Any],
              let id = (meta["session_id"] ?? meta["id"]) as? String else { return nil }
        guard (meta["thread_source"] as? String) != "subagent",
              (meta["source"] as? [String: Any])?["subagent"] == nil else { return nil }
        let cwd = meta["cwd"] as? String
        let title = (meta["name"] ?? meta["title"]) as? String ?? "Untitled"
        let latest = latestUpdate(at: url.path)
        let activity = latest?.activity ?? .idle("Waiting for the next turn", at: modified)
        return DiscoveredSession(
            id: id,
            projectName: cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Codex",
            conversationTitle: String(title.prefix(120)),
            activity: activity,
            capabilities: ProviderCapabilities(liveActivity: true, eventActivity: true, approvals: true, questions: true, jumpToSession: true),
            cwd: cwd,
            updatedAt: modified,
            status: SessionStatus(phase: activity.phase),
            threadID: id,
            rolloutPath: url.path,
            model: meta["model"] as? String,
            reasoningEffort: meta["reasoning_effort"] as? String,
            interaction: latest?.interaction
        )
    }

    nonisolated private static func latestUpdate(at path: String) -> CodexRolloutUpdate? {
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        guard var data = UsageMonitor.readTail(url, bytes: 512 * 1_024) else { return nil }
        if let firstNewline = data.firstIndex(of: 0x0A), (try? JSONSerialization.jsonObject(with: Data(data[..<firstNewline]))) == nil {
            data.removeSubrange(...firstNewline)
        }
        if data.last != 0x0A { data.append(0x0A) }
        return CodexRolloutParser.consumeUpdates(buffer: &data).last
    }
}

private final class CodexRolloutFileWatcher: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "app.notchagents.codex-rollout", qos: .utility)
    private let onUpdate: @Sendable (CodexRolloutUpdate) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var handle: FileHandle?
    private var offset: UInt64 = 0
    private var buffer = Data()
    private var stopped = false

    init(url: URL, onUpdate: @escaping @Sendable (CodexRolloutUpdate) -> Void) {
        self.url = url
        self.onUpdate = onUpdate
    }

    func start() { queue.async { [weak self] in self?.open() } }

    func stop() {
        queue.async { [weak self] in
            self?.stopped = true
            self?.source?.cancel()
            self?.source = nil
            try? self?.handle?.close()
            self?.handle = nil
        }
    }

    private func open() {
        guard !stopped, let handle = try? FileHandle(forReadingFrom: url) else {
            reopenLater()
            return
        }
        self.handle = handle
        offset = (try? handle.seekToEnd()) ?? 0
        let descriptor = handle.fileDescriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in self?.fileChanged() }
        source.setCancelHandler { }
        self.source = source
        source.resume()
    }

    private func fileChanged() {
        guard let source else { return }
        let flags = source.data
        if flags.contains(.rename) || flags.contains(.delete) {
            source.cancel()
            self.source = nil
            try? handle?.close()
            handle = nil
            offset = 0
            buffer.removeAll(keepingCapacity: true)
            reopenLater()
            return
        }
        readAppendedData()
    }

    private func readAppendedData() {
        guard let handle, let size = try? handle.seekToEnd() else { return }
        if size < offset {
            offset = 0
            buffer.removeAll(keepingCapacity: true)
        }
        guard size > offset else { return }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.read(upToCount: Int(size - offset)), !data.isEmpty else { return }
        offset = size
        buffer.append(data)
        CodexRolloutParser.consumeUpdates(buffer: &buffer).forEach(onUpdate)
    }

    private func reopenLater() {
        guard !stopped else { return }
        queue.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.open() }
    }
}
