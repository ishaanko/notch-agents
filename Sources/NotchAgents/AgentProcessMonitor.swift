import Foundation

struct AgentProcessSnapshot: Equatable, Sendable {
    var agent: AgentKind
    var processID: Int32
    var sessionID: String?
    var workingDirectory: String?
    var terminalTTY: String?
    var terminalBundleID: String?
    var projectName: String? = nil
    var conversationTitle: String? = nil
    var activityText: String? = nil
    var observedPhase: ActivityPhase? = nil
    var model: String? = nil
    var interaction: AgentInteraction? = nil
    var backingSessionID: String? = nil
    var updatedAt: Date? = nil
}

struct RunningProcessRecord: Equatable, Sendable {
    var processID: Int32
    var parentProcessID: Int32
    var terminalTTY: String?
    var command: String
}

enum AgentProcessParser {
    private static let wrappers: Set<String> = [
        "node", "bun", "deno", "npx", "npm", "pnpm", "yarn", "env",
    ]
    private static let ignoredExecutables: Set<String> = [
        "zsh", "bash", "sh", "fish", "rg", "grep", "ps",
    ]
    private static let executableAgents: [String: AgentKind] = {
        var result: [String: AgentKind] = [:]
        for descriptor in AgentIntegrationCatalog.descriptors {
            for name in descriptor.executableNames {
                result[name.lowercased()] = descriptor.agent
            }
        }
        return result
    }()

    static func parseProcessList(_ output: String) -> [RunningProcessRecord] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let parts = rawLine
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(maxSplits: 3, whereSeparator: \.isWhitespace)
            guard parts.count == 4,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]) else { return nil }
            let tty = String(parts[2])
            return RunningProcessRecord(
                processID: pid,
                parentProcessID: ppid,
                terminalTTY: tty == "??" || tty == "-" ? nil : tty,
                command: String(parts[3])
            )
        }
    }

    static func agent(for command: String) -> AgentKind? {
        let lower = command.lowercased()
        guard !lower.contains("notchagents"),
              !lower.contains("notch-agents"),
              !lower.contains("/.codex/plugins/"),
              !lower.contains(".app/contents/frameworks/"),
              // A host application's main executable is not an active coding
              // turn. This also avoids treating spaces in paths such as
              // ".../Codex Computer Use.app/Contents/MacOS/..." as arguments.
              !lower.contains(".app/contents/macos/"),
              !lower.contains(" app-server"),
              !lower.contains(" codex sandbox"),
              !lower.contains(" codex exec") else { return nil }

        let tokens = lower.split(whereSeparator: \.isWhitespace).prefix(5).map(String.init)
        guard let first = tokens.first else { return nil }
        let firstBase = executableBaseName(first)
        guard !ignoredExecutables.contains(firstBase) else { return nil }
        let candidates = wrappers.contains(firstBase) ? Array(tokens.dropFirst()) : [first]

        let descriptorAgent: AgentKind? = candidates.compactMap { token in
            let path = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if let exact = executableAgents[executableBaseName(path)] {
                return exact
            }
            return executableAgents.first(where: {
                path.contains("/.bin/\($0.key)")
            })?.value
        }.first
        let packageAgent: AgentKind? = candidates.compactMap { token in
            let path = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if path.contains("/@opencode-ai/") || path.contains("/node_modules/opencode/") {
                return .opencode
            }
            if path.contains("/@mimo-ai/cli/") {
                return .mimocode
            }
            return nil
        }.first
        guard let agent = descriptorAgent ?? packageAgent else { return nil }
        if agent == .codex {
            let excludedSubcommands: Set<String> = ["app-server", "sandbox", "exec"]
            if tokens.contains(where: { excludedSubcommands.contains($0) }) { return nil }
        }
        return agent
    }

    private static func executableBaseName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(
            in: CharacterSet(charactersIn: "\"'")
        )
        return trimmed.split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init)
            ?? trimmed
    }

    static func sessionID(command: String, lsofOutput: String?) -> String? {
        let flagPatterns = [
            #"(?:--session-id|--session_id|--resume)\s+["']?([A-Za-z0-9_-]{8,})"#,
            #"(?:--thread-id|--thread_id)\s+["']?([A-Za-z0-9_-]{8,})"#,
        ]
        for pattern in flagPatterns {
            if let match = firstCapture(pattern, in: command) { return match }
        }

        guard let lsofOutput else { return nil }
        let filePatterns = [
            #"/(?:sessions|projects)/[^\n]*/?([0-9a-fA-F]{8}-[0-9a-fA-F-]{20,})\.jsonl"#,
            #"/(?:sessions|projects)/[^\n]*/?([A-Za-z0-9_-]{12,})\.jsonl"#,
        ]
        for pattern in filePatterns {
            if let match = firstCapture(pattern, in: lsofOutput) { return match }
        }
        return nil
    }

    static func workingDirectory(fromLsof output: String?) -> String? {
        guard let output else { return nil }
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        for index in lines.indices where lines[index] == "fcwd" {
            let next = lines.index(after: index)
            if next < lines.endIndex, lines[next].hasPrefix("n") {
                return String(lines[next].dropFirst())
            }
        }
        return nil
    }

    static func terminalBundleID(
        for process: RunningProcessRecord,
        processesByID: [Int32: RunningProcessRecord]
    ) -> String? {
        var current: RunningProcessRecord? = process
        var visited: Set<Int32> = []
        while let item = current, visited.insert(item.processID).inserted {
            let command = item.command.lowercased()
            if command.contains("codex.app/") { return "com.openai.codex" }
            if command.contains("t3 code") && command.contains(".app/") { return "com.t3tools.t3code" }
            if command.contains("conductor.app/") { return "com.conductor.app" }
            if command.contains("iterm.app/") || command.contains("iterm2.app/") { return "com.googlecode.iterm2" }
            if command.contains("ghostty.app/") { return "com.mitchellh.ghostty" }
            if command.contains("warp.app/") { return "dev.warp.Warp-Stable" }
            if command.contains("terminal.app/") { return "com.apple.Terminal" }
            if command.contains("cursor.app/") { return "com.todesktop.230313mzl4w4u92" }
            if command.contains("visual studio code.app/") { return "com.microsoft.VSCode" }
            if command.contains("windsurf.app/") { return "com.exafunction.windsurf" }
            if command.contains("wezterm") { return "com.github.wez.wezterm" }
            current = processesByID[item.parentProcessID]
        }
        return nil
    }

    private static func firstCapture(_ pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }
}

final class AgentProcessDiscovery: @unchecked Sendable {
    typealias CommandRunner = @Sendable (_ executable: String, _ arguments: [String]) -> String?

    private let commandRunner: CommandRunner
    private let home: URL
    private var processEnrichmentCache: [
        Int32: (command: String, cwd: String?, sessionID: String?)
    ] = [:]

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        commandRunner: @escaping CommandRunner = { executable, arguments in
            AgentProcessDiscovery.run(executable, arguments)
        }
    ) {
        self.home = home
        self.commandRunner = commandRunner
    }

    func discover() -> [AgentProcessSnapshot] {
        guard let output = commandRunner("/bin/ps", ["-Ao", "pid=,ppid=,tty=,command="]) else { return [] }
        let processes = AgentProcessParser.parseProcessList(output)
        let byID = Dictionary(uniqueKeysWithValues: processes.map { ($0.processID, $0) })
        let runningProcessIDs = Set(processes.map(\.processID))
        processEnrichmentCache = processEnrichmentCache.filter {
            runningProcessIDs.contains($0.key)
        }
        var claimed: Set<String> = []
        var result: [AgentProcessSnapshot] = []

        var antigravityHost: RunningProcessRecord?
        for process in processes {
            guard let agent = AgentProcessParser.agent(for: process.command) else { continue }
            if agent == .antigravity, antigravityHost == nil {
                antigravityHost = process
            }
            // Provider hooks own identity. Process discovery only enriches
            // interactive terminal sessions; headless helpers are not chats.
            guard process.terminalTTY != nil || agent == .opencode else { continue }
            let hostBundleID = AgentProcessParser.terminalBundleID(for: process, processesByID: byID)
            // T3's Electron shell and bin.mjs server are permanent. Its state
            // database below is stronger evidence than a provider subprocess,
            // which may remain warm between turns.
            if hostBundleID == "com.t3tools.t3code" { continue }
            let cached = processEnrichmentCache[process.processID].flatMap {
                $0.command == process.command ? $0 : nil
            }
            let cwd: String?
            let sessionID: String?
            let needsExactSession = [.codex, .claude, .cursor].contains(agent)
            if let cached,
               cached.sessionID != nil || (!needsExactSession && cached.cwd != nil) {
                cwd = cached.cwd
                sessionID = cached.sessionID
            } else {
                let lsof = commandRunner(
                    "/usr/sbin/lsof",
                    ["-a", "-p", "\(process.processID)", "-Fn"]
                )
                cwd = AgentProcessParser.workingDirectory(fromLsof: lsof)
                sessionID = AgentProcessParser.sessionID(
                    command: process.command,
                    lsofOutput: lsof
                )
                processEnrichmentCache[process.processID] = (
                    process.command,
                    cwd,
                    sessionID
                )
            }
            if agent == .codex, sessionID == nil { continue }
            if [.claude, .cursor].contains(agent), sessionID == nil, cwd == nil { continue }
            if agent == .claude, cwd?.contains("/.claude/worktrees/agent-") == true { continue }
            let key = sessionID.map { "\(agent.rawValue):\($0)" }
                ?? "\(agent.rawValue):\(process.terminalTTY ?? "\(process.processID)"):\(cwd ?? "")"
            guard claimed.insert(key).inserted else { continue }
            result.append(AgentProcessSnapshot(
                agent: agent,
                processID: process.processID,
                sessionID: sessionID,
                workingDirectory: cwd,
                terminalTTY: process.terminalTTY,
                terminalBundleID: hostBundleID
            ))
        }
        result.append(contentsOf: discoverActiveT3Sessions(in: processes))
        result.append(contentsOf: discoverAntigravityAttention(host: antigravityHost))
        return result
    }

    private func discoverAntigravityAttention(
        host: RunningProcessRecord?
    ) -> [AgentProcessSnapshot] {
        guard let host else { return [] }
        let root = home.appendingPathComponent(".gemini/antigravity-cli/conversations", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let separator = "\u{1f}"
        return files.compactMap { database in
            guard database.pathExtension == "db",
                  let output = commandRunner(
                    "/usr/bin/sqlite3",
                    [
                        "-readonly", "-separator", separator, database.path,
                        "SELECT idx, step_type FROM steps INDEXED BY idx_steps_status WHERE status = 9 ORDER BY idx DESC LIMIT 1;",
                    ]
                  ),
                  let line = output.split(whereSeparator: \.isNewline).first else { return nil }
            let fields = String(line).components(separatedBy: separator)
            guard fields.count == 2, !fields[0].isEmpty else { return nil }
            let conversationID = database.deletingPathExtension().lastPathComponent
            let prompt = "Antigravity needs your attention"
            return AgentProcessSnapshot(
                agent: .antigravity,
                processID: host.processID,
                sessionID: conversationID,
                workingDirectory: nil,
                terminalTTY: host.terminalTTY,
                terminalBundleID: "com.google.antigravity",
                projectName: "Antigravity",
                conversationTitle: "Attention needed",
                activityText: prompt,
                observedPhase: .waiting
            )
        }
    }

    private func discoverActiveT3Sessions(in processes: [RunningProcessRecord]) -> [AgentProcessSnapshot] {
        guard let host = processes.first(where: {
            let command = $0.command.lowercased()
            return command.contains("t3 code")
                && command.contains(".app/contents/macos/t3 code")
                && !command.contains("apps/server/dist/bin.mjs")
        }) else { return [] }

        let database = home.appendingPathComponent(".t3/userdata/state.sqlite").path
        let separator = "\u{1f}"
        let query = """
        SELECT t.thread_id,
               replace(coalesce(p.workspace_root, ''), char(31), ' '),
               replace(coalesce(p.title, ''), char(31), ' '),
               replace(coalesce(t.title, ''), char(31), ' '),
               replace(coalesce(json_extract(t.model_selection_json, '$.model'), ''), char(31), ' '),
               replace(coalesce((
                   SELECT a.summary
                   FROM projection_thread_activities a
                   WHERE a.thread_id = t.thread_id
                   ORDER BY coalesce(a.sequence, 0) DESC, a.created_at DESC
                   LIMIT 1
               ), 'Working'), char(31), ' '),
               coalesce(t.pending_approval_count, 0),
               coalesce(t.pending_user_input_count, 0),
               replace(coalesce((
                   SELECT a.activity_id
                   FROM projection_thread_activities a
                   WHERE a.thread_id = t.thread_id
                     AND a.kind IN ('approval.requested', 'user-input.requested')
                   ORDER BY coalesce(a.sequence, 0) DESC, a.created_at DESC
                   LIMIT 1
               ), ''), char(31), ' '),
               replace(coalesce((
                   SELECT a.kind
                   FROM projection_thread_activities a
                   WHERE a.thread_id = t.thread_id
                     AND a.kind IN ('approval.requested', 'user-input.requested')
                   ORDER BY coalesce(a.sequence, 0) DESC, a.created_at DESC
                   LIMIT 1
               ), ''), char(31), ' '),
               replace(coalesce((
                   SELECT a.summary
                   FROM projection_thread_activities a
                   WHERE a.thread_id = t.thread_id
                     AND a.kind IN ('approval.requested', 'user-input.requested')
                   ORDER BY coalesce(a.sequence, 0) DESC, a.created_at DESC
                   LIMIT 1
               ), ''), char(31), ' '),
               replace(coalesce((
                   SELECT a.payload_json
                   FROM projection_thread_activities a
                   WHERE a.thread_id = t.thread_id
                     AND a.kind IN ('approval.requested', 'user-input.requested')
                   ORDER BY coalesce(a.sequence, 0) DESC, a.created_at DESC
                   LIMIT 1
               ), ''), char(31), ' '),
               replace(coalesce(
                   nullif(s.provider_thread_id, ''),
                   nullif(s.provider_session_id, ''),
                   json_extract(r.resume_cursor_json, '$.threadId'),
                   ''
               ), char(31), ' '),
               CASE
                   WHEN coalesce(s.updated_at, '') > t.updated_at THEN s.updated_at
                   ELSE t.updated_at
               END
        FROM projection_threads t
        LEFT JOIN projection_thread_sessions s ON s.thread_id = t.thread_id
        LEFT JOIN provider_session_runtime r ON r.thread_id = t.thread_id
        LEFT JOIN projection_projects p ON p.project_id = t.project_id
        WHERE (
            (s.active_turn_id IS NOT NULL AND EXISTS (
                SELECT 1 FROM projection_turns turn
                WHERE turn.thread_id = s.thread_id
                  AND turn.turn_id = s.active_turn_id
                  AND turn.state = 'running'
            ))
            OR t.pending_approval_count > 0
            OR t.pending_user_input_count > 0
          )
          AND t.deleted_at IS NULL;
        """
        guard let output = commandRunner(
            "/usr/bin/sqlite3",
            ["-readonly", "-separator", separator, database, query]
        ) else { return [] }
        return Self.parseT3Sessions(output, processID: host.processID, separator: separator)
    }

    static func parseT3Sessions(
        _ output: String,
        processID: Int32,
        separator: String = "\u{1f}"
    ) -> [AgentProcessSnapshot] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = String(line).components(separatedBy: separator)
            guard fields.count >= 12, !fields[0].isEmpty else { return nil }
            let interaction = t3Interaction(
                threadID: fields[0],
                approvalCount: Int(fields[6]) ?? 0,
                inputCount: Int(fields[7]) ?? 0,
                activityID: fields[8],
                kind: fields[9],
                summary: fields[10],
                payloadJSON: fields[11]
            )
            return AgentProcessSnapshot(
                agent: .t3code,
                processID: processID,
                sessionID: fields[0],
                workingDirectory: fields[1].isEmpty ? nil : fields[1],
                terminalTTY: nil,
                terminalBundleID: "com.t3tools.t3code",
                projectName: fields[2].isEmpty ? nil : fields[2],
                conversationTitle: fields[3].isEmpty ? nil : fields[3],
                activityText: interaction?.firstPrompt ?? (fields[5].isEmpty ? nil : fields[5]),
                model: fields[4].isEmpty ? nil : fields[4],
                interaction: interaction,
                backingSessionID: fields.count > 12 && !fields[12].isEmpty ? fields[12] : nil,
                updatedAt: fields.count > 13 ? parseTimestamp(fields[13]) : nil
            )
        }
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func t3Interaction(
        threadID: String,
        approvalCount: Int,
        inputCount: Int,
        activityID: String,
        kind: String,
        summary: String,
        payloadJSON: String
    ) -> AgentInteraction? {
        guard approvalCount > 0 || inputCount > 0 else { return nil }
        let payload = payloadJSON.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            ?? [:]
        let isQuestion = kind == "user-input.requested" || (inputCount > 0 && approvalCount == 0)
        let fallbackPrompt = isQuestion ? "T3 Code needs your input" : "T3 Code needs approval"
        let prompt = PayloadValue.string(in: payload, keys: [
            "prompt", "question", "message",
        ]) ?? (!summary.isEmpty ? summary : fallbackPrompt)
        let detail = PayloadValue.cleaned(
            PayloadValue.string(in: payload, keys: ["detail", "command", "path", "file"]),
            limit: 1_200
        )
        let requestID = PayloadValue.string(in: payload, keys: ["requestId", "request_id"])
            ?? (!activityID.isEmpty ? activityID : "\(threadID):\(isQuestion ? "input" : "approval")")
        let questions = isQuestion
            ? t3Questions(in: payload, fallbackPrompt: prompt, fallbackDetail: detail)
            : [AgentQuestion(
                id: "t3-fallback",
                prompt: prompt,
                detail: detail,
                options: [
                    AgentQuestionOption(label: "Decline", value: "deny", permissionDecision: .deny),
                    AgentQuestionOption(label: "Accept", value: "allow", permissionDecision: .allow),
                ]
            )]
        return AgentInteraction(
            requestID: requestID,
            kind: isQuestion ? .question : .permission,
            provider: .t3code,
            questions: questions,
            capability: .transportReply,
            expiresAt: nil,
            replyRoute: InteractionReplyRoute(
                transport: .t3Orchestration,
                threadID: threadID,
                requestID: requestID
            )
        )
    }

    private static func t3Questions(
        in payload: [String: Any],
        fallbackPrompt: String,
        fallbackDetail: String?
    ) -> [AgentQuestion] {
        guard let rawQuestions = payload["questions"] as? [[String: Any]],
              !rawQuestions.isEmpty else {
            return [AgentQuestion(
                id: "t3-fallback",
                prompt: fallbackPrompt,
                detail: fallbackDetail,
                allowsOther: true
            )]
        }
        return rawQuestions.enumerated().map { index, raw in
            let id = PayloadValue.string(in: raw, keys: ["id"])
                ?? "t3-question-\(index + 1)"
            let header = PayloadValue.string(in: raw, keys: ["header"])
            let prompt = PayloadValue.string(in: raw, keys: ["question", "prompt"])
                ?? fallbackPrompt
            let options: [AgentQuestionOption] = (
                raw["options"] as? [[String: Any]] ?? []
            ).compactMap { option -> AgentQuestionOption? in
                guard let label = PayloadValue.string(in: option, keys: ["label"]) else {
                    return nil
                }
                let description = PayloadValue.string(
                    in: option,
                    keys: ["description", "detail"]
                )
                return AgentQuestionOption(
                    label: label,
                    value: label,
                    detail: description
                )
            }
            return AgentQuestion(
                id: id,
                header: header,
                prompt: prompt,
                detail: fallbackDetail,
                options: options,
                allowsOther: options.isEmpty,
                allowsMultiple: raw["multiSelect"] as? Bool ?? false
            )
        }
    }

    fileprivate static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // Drain before waiting: `ps` can exceed the pipe buffer on systems
            // with Electron apps and very long command lines.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

final class AgentProcessMonitor: @unchecked Sendable {
    private let discovery: AgentProcessDiscovery
    private let onChange: @Sendable ([AgentProcessSnapshot]) -> Void
    private let queue = DispatchQueue(label: "app.notchagents.process-monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastSnapshots: [AgentProcessSnapshot]?

    init(
        discovery: AgentProcessDiscovery = AgentProcessDiscovery(),
        onChange: @escaping @Sendable ([AgentProcessSnapshot]) -> Void
    ) {
        self.discovery = discovery
        self.onChange = onChange
    }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 30, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let snapshots = self.discovery.discover()
            guard snapshots != self.lastSnapshots else { return }
            self.lastSnapshots = snapshots
            self.onChange(snapshots)
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        lastSnapshots = nil
    }
}
