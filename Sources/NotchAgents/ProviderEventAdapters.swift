import Foundation

struct ProviderEvent {
    var eventName: String
    var sessionID: String?
    var projectName: String?
    var conversationTitle: String?
    var cwd: String?
    var activity: LiveActivity
    var capabilities: ProviderCapabilities
    var terminalBundleID: String?
    var terminalSessionID: String?
    var threadID: String?
    var interaction: AgentInteraction?
    var model: String?
    var beginsTurn: Bool
}

protocol ProviderEventAdapter {
    var agent: AgentKind { get }
    var capabilities: ProviderCapabilities { get }
    func normalize(_ payload: [String: Any]) -> ProviderEvent?
}

struct ProviderEventAdapterRegistry {
    static let shared = ProviderEventAdapterRegistry()

    private let adapters: [AgentKind: any ProviderEventAdapter]
    private let fallback: any ProviderEventAdapter

    init() {
        let approvalProviders: Set<AgentKind> = [
            .claude, .codex, .cursor, .opencode, .droid, .qoder, .qwen, .codebuddy,
        ]
        let questionProviders: Set<AgentKind> = [
            .claude, .opencode, .droid, .qoder, .qwen, .codebuddy,
        ]
        let liveProviders: Set<AgentKind> = [.codex, .antigravity]
        var values: [AgentKind: any ProviderEventAdapter] = [:]
        for agent in AgentKind.allCases where agent != .unknown {
            let configured = ModelPreferences.supportedAgents.contains(agent) || [.cursor, .qoder].contains(agent)
            values[agent] = CommonProviderEventAdapter(
                agent: agent,
                capabilities: ProviderCapabilities(
                    liveActivity: liveProviders.contains(agent),
                    eventActivity: configured,
                    approvals: approvalProviders.contains(agent),
                    questions: questionProviders.contains(agent),
                    jumpToSession: true
                ),
                defaultBlockingReplies: approvalProviders.contains(agent)
            )
        }
        adapters = values
        fallback = CommonProviderEventAdapter(agent: .unknown, capabilities: .displayOnly, defaultBlockingReplies: false)
    }

    func adapter(for agent: AgentKind) -> any ProviderEventAdapter {
        adapters[agent] ?? fallback
    }
}

private struct CommonProviderEventAdapter: ProviderEventAdapter {
    let agent: AgentKind
    let capabilities: ProviderCapabilities
    let defaultBlockingReplies: Bool

    func normalize(_ payload: [String: Any]) -> ProviderEvent? {
        let eventName = PayloadValue.string(in: payload, keys: [
            "hook_event_name", "event_name", "event", "type", "notification_type", "kind"
        ]) ?? "activity"
        let status = PayloadValue.string(in: payload, keys: ["status", "state"])?.lowercased() ?? ""
        let event = eventName.lowercased()
        let tool = PayloadValue.string(in: payload, keys: ["tool_name", "tool", "command", "action"])
        let normalizedTool = tool?.lowercased() ?? ""
        let isQuestion = event.contains("question")
            || event.hasPrefix("ask")
            || event.contains("_ask_")
            || normalizedTool == "askuserquestion"
            || normalizedTool == "request_user_input"
        let cursorBlocks = agent == .cursor
            && (event.contains("beforeshellexecution") || event.contains("beforemcpexecution"))
        let isPermission = !isQuestion && (
            event.contains("permission") || event.contains("approval")
                || status.contains("approval") || cursorBlocks
        )
        let replyCapability = (isPermission || isQuestion)
            ? replyCapability(
                in: payload,
                forceBlocking: cursorBlocks,
                isQuestion: isQuestion
            )
            : .displayOnly
        let ownsInteraction = replyCapability.supportsInlineReply
        let phase = phase(
            event: event,
            status: status,
            payload: payload,
            permission: isPermission && ownsInteraction,
            question: isQuestion && ownsInteraction,
            unhostedInput: (isPermission || isQuestion) && !ownsInteraction
        )
        let text = activityText(payload, eventName: eventName, phase: phase, tool: tool)
        let now = Date()
        let explicitLive = PayloadValue.bool(in: payload, keys: ["is_live", "streaming", "live"])
        let live = explicitLive ?? (capabilities.liveActivity && [.working, .thinking, .tool, .editing].contains(phase))
        let requestID = PayloadValue.string(in: payload, keys: [
            "request_id", "requestId", "call_id", "tool_call_id", "tool_use_id",
        ])
            ?? UUID().uuidString
        let interaction: AgentInteraction?
        if (isPermission || isQuestion) && ownsInteraction {
            let kind: InteractionKind = isPermission ? .permission : .question
            interaction = AgentInteraction(
                requestID: requestID,
                kind: kind,
                provider: agent,
                questions: questions(
                    in: payload,
                    kind: kind,
                    tool: tool,
                    detail: interactionDetail(in: payload, kind: kind)
                ),
                capability: replyCapability,
                expiresAt: expiresAt(in: payload),
                responseContext: responseContext(in: payload, isQuestion: isQuestion)
            )
        } else {
            interaction = nil
        }

        let cwd = PayloadValue.string(in: payload, keys: [
            "cwd", "working_directory", "workingDirectory", "project_path", "workspace"
        ]) ?? PayloadValue.firstString(in: payload, keys: ["workspacePaths", "workspace_paths"])
        let project = PayloadValue.string(in: payload, keys: ["project", "project_name", "repo_name"])
            ?? cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
        let conversationTitle = PayloadValue.string(in: payload, keys: [
            "conversation_title", "conversationTitle", "session_title", "chat_title", "thread_name", "name", "title"
        ])

        return ProviderEvent(
            eventName: eventName,
            sessionID: PayloadValue.string(in: payload, keys: [
                "session_id", "sessionId", "conversation_id", "conversationId", "thread_id", "threadId"
            ]),
            projectName: project,
            conversationTitle: PayloadValue.cleaned(conversationTitle, limit: 120),
            cwd: cwd,
            activity: LiveActivity(
                phase: phase,
                text: text,
                toolName: tool,
                updatedAt: now,
                isLive: live
            ),
            capabilities: capabilities,
            terminalBundleID: PayloadValue.string(in: payload, keys: ["terminal_bundle_id", "bundle_id", "terminalBundleId"]),
            terminalSessionID: PayloadValue.string(in: payload, keys: ["terminal_session_id", "iterm_session_id", "tty"]),
            threadID: PayloadValue.string(in: payload, keys: ["thread_id", "threadId", "codex_thread_id"]),
            interaction: interaction,
            model: PayloadValue.string(in: payload, keys: ["model", "model_id", "modelId", "model_name"]),
            beginsTurn: event.contains("userprompt") || event.contains("turn_start") || event.contains("task_started")
                || event.contains("sessionstart") || event.contains("preinvocation")
        )
    }

    private func phase(
        event: String,
        status: String,
        payload: [String: Any],
        permission: Bool,
        question: Bool,
        unhostedInput: Bool
    ) -> ActivityPhase {
        if permission { return .approval }
        if question { return .question }
        if unhostedInput { return .waiting }
        if agent == .antigravity {
            if PayloadValue.string(in: payload, keys: ["error"]) != nil
                || status == "failed" {
                return .failed
            }
            if event.contains("stop") {
                return PayloadValue.bool(in: payload, keys: ["fullyIdle", "fully_idle"]) == true
                    ? .succeeded
                    : .working
            }
            if event.contains("preinvocation") { return .thinking }
        }
        if event.contains("fail") || event.contains("error") || status == "failed" { return .failed }
        if event.contains("complete") || event.contains("finish") || event.contains("stop") || status == "completed" { return .succeeded }
        if event.contains("patch") || event.contains("edit") || PayloadValue.value(in: payload, keys: ["patch", "diff"]) != nil {
            return .editing
        }
        if event.contains("tool") || PayloadValue.string(in: payload, keys: ["tool_name", "command", "action"]) != nil {
            return .tool
        }
        if event.contains("wait") || event.contains("idle") || status == "waiting" { return .waiting }
        if event.contains("reason") || event.contains("think")
            || PayloadValue.string(in: payload, keys: ["thinking", "reasoning", "status_text", "delta"]) != nil {
            return .thinking
        }
        return status == "idle" ? .idle : .working
    }

    private func activityText(
        _ payload: [String: Any],
        eventName: String,
        phase: ActivityPhase,
        tool: String?
    ) -> String {
        let keys: [String]
        switch phase {
        case .working:
            keys = ["status_text", "assistant_message", "prompt", "message", "summary", "description"]
        case .thinking:
            keys = ["status_text", "thinking", "reasoning", "delta", "assistant_message", "message", "summary"]
        case .tool:
            keys = ["status_text", "command", "action", "tool_name", "message", "description"]
        case .editing:
            keys = ["status_text", "patch", "path", "file", "message", "description"]
        case .failed:
            keys = ["error", "message", "result", "description"]
        default:
            keys = ["status_text", "assistant_message", "last_assistant_message", "message", "result", "description", "detail"]
        }
        if let value = PayloadValue.cleaned(PayloadValue.string(in: payload, keys: keys), limit: 260) {
            return value
        }
        if phase == .tool, let tool { return "Using \(tool)" }
        return eventName.replacingOccurrences(of: "_", with: " ")
    }

    private func questions(
        in payload: [String: Any],
        kind: InteractionKind,
        tool: String?,
        detail: String?
    ) -> [AgentQuestion] {
        let nested = PayloadValue.arrays(in: payload, keys: ["questions"])
        if !nested.isEmpty {
            return nested.enumerated().map { index, item in
                parseQuestion(item, fallbackID: "question-\(index + 1)", kind: kind, detail: detail)
            }
        }
        if let question = PayloadValue.dictionary(in: payload, keys: ["question"]) {
            return [parseQuestion(question, fallbackID: "question-1", kind: kind, detail: detail)]
        }
        let prompt = PayloadValue.string(in: payload, keys: ["prompt", "question", "message", "notification"])
            ?? (kind == .permission ? tool.map { "Allow \($0)?" } : nil)
            ?? (kind == .permission ? "Allow this action?" : "Agent needs input")
        var options = parseOptions(
            PayloadValue.array(in: payload, keys: ["options", "choices"])
                ?? (kind == .permission ? ["Deny", "Allow"] : [])
        )
        if kind == .permission { options = permissionOptions(options) }
        return [AgentQuestion(
            id: PayloadValue.string(in: payload, keys: ["question_id", "id"]) ?? "question-1",
            header: PayloadValue.string(in: payload, keys: ["header"]),
            prompt: prompt,
            detail: detail == prompt ? nil : detail,
            options: options,
            allowsOther: PayloadValue.bool(in: payload, keys: ["allows_other", "allow_other", "free_text"]) ?? (options.isEmpty && kind == .question),
            allowsMultiple: PayloadValue.bool(in: payload, keys: ["allows_multiple", "multiple", "multi_select"]) ?? false,
            required: PayloadValue.bool(in: payload, keys: ["required"]) ?? true
        )]
    }

    private func parseQuestion(
        _ item: [String: Any],
        fallbackID: String,
        kind: InteractionKind,
        detail: String?
    ) -> AgentQuestion {
        let prompt = PayloadValue.string(in: item, keys: ["prompt", "question", "message", "title"]) ?? "Agent needs input"
        return AgentQuestion(
            id: PayloadValue.string(in: item, keys: ["id", "question_id", "questionId"]) ?? fallbackID,
            header: PayloadValue.string(in: item, keys: ["header", "label"]),
            prompt: prompt,
            detail: PayloadValue.string(in: item, keys: ["detail", "description"]) ?? (detail == prompt ? nil : detail),
            options: {
                let parsed = parseOptions(PayloadValue.array(in: item, keys: ["options", "choices"]) ?? (kind == .permission ? ["Deny", "Allow"] : []))
                return kind == .permission ? permissionOptions(parsed) : parsed
            }(),
            allowsOther: PayloadValue.bool(in: item, keys: ["allows_other", "allow_other", "free_text"])
                ?? (kind == .question),
            allowsMultiple: PayloadValue.bool(in: item, keys: [
                "allows_multiple", "multiple", "multi_select", "multiSelect",
            ]) ?? false,
            required: PayloadValue.bool(in: item, keys: ["required"]) ?? true
        )
    }

    private func interactionDetail(
        in payload: [String: Any],
        kind: InteractionKind
    ) -> String? {
        if let value = PayloadValue.cleaned(
            PayloadValue.string(
                in: payload,
                keys: ["command", "cmd", "patch", "diff", "path", "file", "query", "url"]
            ),
            limit: 4_000
        ) {
            return value
        }

        if kind == .permission,
           let value = PayloadValue.cleaned(
               PayloadValue.string(
                   in: payload,
                   keys: ["tool_input", "toolInput", "arguments", "input"]
               ),
               limit: 4_000
           ) {
            return value
        }

        if let value = PayloadValue.cleaned(
            PayloadValue.string(in: payload, keys: ["detail", "description"]),
            limit: 4_000
        ) {
            return value
        }

        guard kind == .permission,
              let input = PayloadValue.dictionary(
                in: payload,
                keys: ["tool_input", "toolInput", "arguments", "input"]
              ),
              JSONSerialization.isValidJSONObject(input),
              let data = try? JSONSerialization.data(
                withJSONObject: input,
                options: [.prettyPrinted, .sortedKeys]
              ),
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return PayloadValue.cleaned(value, limit: 4_000)
    }

    private func parseOptions(_ items: [Any]) -> [AgentQuestionOption] {
        items.compactMap { item in
            if let value = item as? String { return AgentQuestionOption(label: value) }
            guard let item = item as? [String: Any],
                  let label = PayloadValue.string(in: item, keys: ["label", "title", "value"]) else { return nil }
            let value = PayloadValue.string(in: item, keys: ["value", "id"]) ?? label
            let decision = PayloadValue.string(in: item, keys: ["decision", "behavior"]).flatMap(PermissionDecision.init(rawValue:))
            return AgentQuestionOption(
                id: PayloadValue.string(in: item, keys: ["id"]) ?? value,
                label: label,
                value: value,
                detail: PayloadValue.string(in: item, keys: ["description", "detail"]),
                permissionDecision: decision
            )
        }
    }

    private func permissionOptions(_ options: [AgentQuestionOption]) -> [AgentQuestionOption] {
        guard !options.isEmpty else {
            return [
                AgentQuestionOption(label: "Deny", value: "deny", permissionDecision: .deny),
                AgentQuestionOption(label: "Allow", value: "allow", permissionDecision: .allow),
            ]
        }
        if options.contains(where: { $0.permissionDecision != nil }) { return options }
        guard options.count == 2 else { return options }
        return [
            AgentQuestionOption(
                id: options[0].id,
                label: options[0].label,
                value: options[0].value,
                detail: options[0].detail,
                permissionDecision: .deny
            ),
            AgentQuestionOption(
                id: options[1].id,
                label: options[1].label,
                value: options[1].value,
                detail: options[1].detail,
                permissionDecision: .allow
            ),
        ]
    }

    private func replyCapability(
        in payload: [String: Any],
        forceBlocking: Bool,
        isQuestion: Bool
    ) -> ReplyCapability {
        let supportsReply = isQuestion ? capabilities.questions : capabilities.approvals
        guard supportsReply else { return .displayOnly }
        if let raw = PayloadValue.string(
            in: payload,
            keys: ["reply_capability", "response_capability"]
        ) {
            if raw == "openInAgent" { return .displayOnly }
            if let capability = ReplyCapability(rawValue: raw) {
                return capability
            }
        }
        if PayloadValue.bool(in: payload, keys: ["display_only"]) == true { return .displayOnly }
        if PayloadValue.bool(in: payload, keys: ["blocking", "expects_reply", "can_respond"]) == true {
            return .blockingReply
        }
        if forceBlocking { return .blockingReply }
        return defaultBlockingReplies ? .blockingReply : .displayOnly
    }

    private func expiresAt(in payload: [String: Any]) -> Date? {
        if let seconds = PayloadValue.number(in: payload, keys: ["expires_at", "expiresAt"]) {
            return Date(timeIntervalSince1970: seconds)
        }
        if let timeout = PayloadValue.number(in: payload, keys: ["timeout_seconds", "timeout"]) {
            return Date().addingTimeInterval(timeout)
        }
        return nil
    }

    private func responseContext(in payload: [String: Any], isQuestion: Bool) -> Data? {
        guard isQuestion,
              let input = PayloadValue.dictionary(in: payload, keys: ["tool_input"]),
              JSONSerialization.isValidJSONObject(input) else { return nil }
        return try? JSONSerialization.data(withJSONObject: input)
    }
}

enum PayloadValue {
    static func value(in payload: [String: Any], keys: [String]) -> Any? {
        for key in keys {
            if let value = payload[key] { return value }
        }
        for key in ["input", "tool_input", "arguments", "data", "payload", "event", "context", "toolCall"] {
            if let nested = payload[key] as? [String: Any], let value = value(in: nested, keys: keys) {
                return value
            }
        }
        return nil
    }

    static func string(in payload: [String: Any], keys: [String]) -> String? {
        if let value = value(in: payload, keys: keys) as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        if let number = value(in: payload, keys: keys) as? NSNumber { return number.stringValue }
        return nil
    }

    static func bool(in payload: [String: Any], keys: [String]) -> Bool? {
        if let bool = value(in: payload, keys: keys) as? Bool { return bool }
        if let number = value(in: payload, keys: keys) as? NSNumber { return number.boolValue }
        if let string = string(in: payload, keys: keys) {
            switch string.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }

    static func number(in payload: [String: Any], keys: [String]) -> Double? {
        if let number = value(in: payload, keys: keys) as? NSNumber { return number.doubleValue }
        if let string = string(in: payload, keys: keys) { return Double(string) }
        return nil
    }

    static func dictionary(in payload: [String: Any], keys: [String]) -> [String: Any]? {
        value(in: payload, keys: keys) as? [String: Any]
    }

    static func array(in payload: [String: Any], keys: [String]) -> [Any]? {
        value(in: payload, keys: keys) as? [Any]
    }

    static func arrays(in payload: [String: Any], keys: [String]) -> [[String: Any]] {
        (array(in: payload, keys: keys) ?? []).compactMap { $0 as? [String: Any] }
    }

    static func firstString(in payload: [String: Any], keys: [String]) -> String? {
        array(in: payload, keys: keys)?
            .compactMap { $0 as? String }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    static func cleaned(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let compact = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return nil }
        return String(compact.prefix(limit))
    }
}
