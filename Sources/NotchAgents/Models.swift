import Foundation

enum AgentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex, cursor, opencode, droid, kiro, copilot
    case antigravity, trae, qoder, qwen, kimi, deepseek, mistral, grok
    case zcode, mimocode, codebuddy, workbuddy, hermes, amp, pi, craft
    case conductor, t3code, warp
    case unknown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .opencode: "OpenCode"
        case .droid: "Factory"
        case .kiro: "Kiro"
        case .copilot: "Copilot"
        case .antigravity: "Antigravity"
        case .trae: "Trae"
        case .qoder: "Qoder"
        case .qwen: "Qwen"
        case .kimi: "Kimi"
        case .deepseek: "DeepSeek"
        case .mistral: "Mistral Vibe"
        case .grok: "Grok Build"
        case .zcode: "ZCode"
        case .mimocode: "MiMoCode"
        case .codebuddy: "CodeBuddy"
        case .workbuddy: "WorkBuddy"
        case .hermes: "Hermes"
        case .amp: "Amp"
        case .pi: "Pi Agent"
        case .craft: "Craft Agent"
        case .conductor: "Conductor"
        case .t3code: "T3 Code"
        case .warp: "Warp · Oz"
        case .unknown: "Agent"
        }
    }

    var questionAskerName: String {
        switch self {
        case .claude: "Claude"
        case .mistral: "Mistral"
        case .warp: "Warp"
        default: displayName
        }
    }

    var glyph: String {
        switch self {
        case .claude: "sparkles"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .cursor: "cursorarrow.rays"
        case .opencode: "terminal.fill"
        default: "cpu"
        }
    }

    /// A compact, non-branded fallback used only when no official bundled
    /// mark or installed application icon is available.
    var identityMark: String {
        switch self {
        case .claude: "CL"
        case .codex: "CX"
        case .cursor: "CU"
        case .opencode: "OC"
        case .droid: "FA"
        case .kiro: "KI"
        case .copilot: "GH"
        case .antigravity: "AG"
        case .trae: "TR"
        case .qoder: "QD"
        case .qwen: "QW"
        case .kimi: "KM"
        case .deepseek: "DS"
        case .mistral: "MV"
        case .grok: "GK"
        case .zcode: "Z"
        case .mimocode: "MI"
        case .codebuddy: "CB"
        case .workbuddy: "WB"
        case .hermes: "HE"
        case .amp: "A"
        case .pi: "PI"
        case .craft: "CR"
        case .conductor: "CD"
        case .t3code: "T3"
        case .warp: "W"
        case .unknown: "AI"
        }
    }

    static func parse(_ value: String?) -> AgentKind {
        let key = (value ?? "").lowercased().replacingOccurrences(of: "-", with: "")
        if key.contains("claude") { return .claude }
        if key.contains("codex") { return .codex }
        if key.contains("antigravity") { return .antigravity }
        if key.contains("cursor") { return .cursor }
        if key.contains("opencode") { return .opencode }
        if key.contains("mimo") { return .mimocode }
        if key.contains("deepseek") || key.contains("codewhale") { return .deepseek }
        if key.contains("mistral") { return .mistral }
        if key.contains("grok") { return .grok }
        if key.contains("droid") || key.contains("factory") { return .droid }
        if key.contains("kiro") { return .kiro }
        if key.contains("copilot") { return .copilot }
        if key.contains("trae") { return .trae }
        if key.contains("qoder") { return .qoder }
        if key.contains("qwen") { return .qwen }
        if key.contains("kimi") { return .kimi }
        if key.contains("zcode") || key.contains("z.ai") { return .zcode }
        if key.contains("codebuddy") { return .codebuddy }
        if key.contains("workbuddy") { return .workbuddy }
        if key.contains("hermes") { return .hermes }
        if key == "amp" || key.contains("ampcode") { return .amp }
        if key.contains("piagent") || key == "pi" { return .pi }
        if key.contains("craft") { return .craft }
        if key.contains("conductor") { return .conductor }
        if key.contains("t3code") || key == "t3" { return .t3code }
        if key.contains("warp") || key == "oz" || key.contains("ozagent") { return .warp }
        return .unknown
    }
}

enum ActivityPhase: String, Codable, CaseIterable, Sendable {
    case working, thinking, tool, editing, waiting, question, approval
    case succeeded, failed, idle

    var accessibilityLabel: String {
        switch self {
        case .working: "Working"
        case .thinking: "Thinking"
        case .tool: "Using a tool"
        case .editing: "Editing files"
        case .waiting: "Waiting"
        case .question: "Question"
        case .approval: "Approval needed"
        case .succeeded: "Completed"
        case .failed: "Failed"
        case .idle: "Idle"
        }
    }
}

struct LiveActivity: Codable, Equatable, Sendable {
    var phase: ActivityPhase
    var text: String
    var toolName: String?
    var updatedAt: Date
    var isLive: Bool

    static func idle(_ text: String = "Waiting for activity", at date: Date = Date()) -> LiveActivity {
        LiveActivity(phase: .idle, text: text, toolName: nil, updatedAt: date, isLive: false)
    }
}

struct ProviderCapabilities: Codable, Equatable, Sendable {
    var liveActivity: Bool
    var eventActivity: Bool
    var approvals: Bool
    var questions: Bool
    var jumpToSession: Bool

    static let displayOnly = ProviderCapabilities(
        liveActivity: false,
        eventActivity: true,
        approvals: false,
        questions: false,
        jumpToSession: false
    )
}

enum SessionStatus: String, Codable, Sendable {
    case running, waiting, needsApproval, question, completed, failed, idle

    var label: String {
        switch self {
        case .running: "WORKING"
        case .waiting: "WAITING"
        case .needsApproval: "APPROVAL"
        case .question: "QUESTION"
        case .completed: "DONE"
        case .failed: "FAILED"
        case .idle: "IDLE"
        }
    }

    init(phase: ActivityPhase) {
        switch phase {
        case .working, .thinking, .tool, .editing: self = .running
        case .waiting: self = .waiting
        case .question: self = .question
        case .approval: self = .needsApproval
        case .succeeded: self = .completed
        case .failed: self = .failed
        case .idle: self = .idle
        }
    }
}

enum InteractionKind: String, Codable, Sendable {
    case permission, question
}

enum ReplyCapability: String, Codable, Sendable {
    case blockingReply, transportReply, displayOnly

    var supportsInlineReply: Bool {
        self == .blockingReply || self == .transportReply
    }

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        // Older persisted sessions used `openInAgent` for passive observations.
        // Passive observers no longer own interactions, so migrate them to
        // display-only state instead of reviving a misleading fallback card.
        self = rawValue == "openInAgent"
            ? .displayOnly
            : ReplyCapability(rawValue: rawValue) ?? .displayOnly
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum SessionOrigin: String, Codable, Sendable {
    case hook
    case process
    case codexHistory
    case appServer
    case demo
}

enum PermissionDecision: String, Codable, Sendable {
    case allow, deny
}

enum ResolvedActivityKind: String, Codable, Sendable {
    case accepted
    case declined
    case answerSubmitted
    case replyFailed
    case completed
}

struct ResolvedActivity: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var kind: ResolvedActivityKind
    var sessionID: String
    var requestID: String?
    var agent: AgentKind
    var projectName: String
    var conversationTitle: String
    var summary: String
    var detail: String?
    var occurredAt: Date

    init(
        id: String = UUID().uuidString,
        kind: ResolvedActivityKind,
        sessionID: String,
        requestID: String? = nil,
        agent: AgentKind,
        projectName: String,
        conversationTitle: String,
        summary: String,
        detail: String? = nil,
        occurredAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.sessionID = sessionID
        self.requestID = requestID
        self.agent = agent
        self.projectName = projectName
        self.conversationTitle = conversationTitle
        self.summary = summary
        self.detail = detail
        self.occurredAt = occurredAt
    }
}

enum InteractionReplyTransport: String, Codable, Sendable {
    case t3Orchestration
}

struct InteractionReplyRoute: Codable, Equatable, Sendable {
    var transport: InteractionReplyTransport
    var threadID: String
    var requestID: String

    init(
        transport: InteractionReplyTransport,
        threadID: String,
        requestID: String
    ) {
        self.transport = transport
        self.threadID = threadID
        self.requestID = requestID
    }
}

struct AgentQuestionOption: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var label: String
    var value: String
    var detail: String?
    var permissionDecision: PermissionDecision?

    init(
        id: String? = nil,
        label: String,
        value: String? = nil,
        detail: String? = nil,
        permissionDecision: PermissionDecision? = nil
    ) {
        self.id = id ?? value ?? label
        self.label = label
        self.value = value ?? label
        self.detail = detail
        self.permissionDecision = permissionDecision
    }
}

struct AgentQuestion: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var header: String?
    var prompt: String
    var detail: String?
    var options: [AgentQuestionOption]
    var allowsOther: Bool
    var allowsMultiple: Bool
    var required: Bool

    init(
        id: String,
        header: String? = nil,
        prompt: String,
        detail: String? = nil,
        options: [AgentQuestionOption] = [],
        allowsOther: Bool = false,
        allowsMultiple: Bool = false,
        required: Bool = true
    ) {
        self.id = id
        self.header = header
        self.prompt = prompt
        self.detail = detail
        self.options = options
        self.allowsOther = allowsOther
        self.allowsMultiple = allowsMultiple
        self.required = required
    }
}

struct QuestionAnswer: Codable, Equatable, Sendable {
    var selectedValues: [String]
    var text: String?

    init(selectedValues: [String] = [], text: String? = nil) {
        self.selectedValues = selectedValues
        self.text = text
    }

    var isEmpty: Bool {
        selectedValues.isEmpty && (text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

struct AgentInteraction: Codable, Equatable, Sendable {
    var requestID: String
    var kind: InteractionKind
    var provider: AgentKind
    var questions: [AgentQuestion]
    var capability: ReplyCapability
    var expiresAt: Date?
    var responseContext: Data?
    var replyRoute: InteractionReplyRoute?

    var firstPrompt: String { questions.first?.prompt ?? "Agent needs input" }

    init(
        requestID: String,
        kind: InteractionKind,
        provider: AgentKind,
        questions: [AgentQuestion],
        capability: ReplyCapability,
        expiresAt: Date?,
        responseContext: Data? = nil,
        replyRoute: InteractionReplyRoute? = nil
    ) {
        self.requestID = requestID
        self.kind = kind
        self.provider = provider
        self.questions = questions
        self.capability = capability
        self.expiresAt = expiresAt
        self.responseContext = responseContext
        self.replyRoute = replyRoute
    }

    private enum CodingKeys: String, CodingKey {
        case requestID, kind, provider, questions, capability, expiresAt, responseContext, replyRoute
        case title, detail, options
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(InteractionKind.self, forKey: .kind)
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID) ?? UUID().uuidString
        provider = try container.decodeIfPresent(AgentKind.self, forKey: .provider) ?? .unknown
        capability = try container.decodeIfPresent(
            ReplyCapability.self,
            forKey: .capability
        ) ?? .displayOnly
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        responseContext = try container.decodeIfPresent(Data.self, forKey: .responseContext)
        replyRoute = try container.decodeIfPresent(InteractionReplyRoute.self, forKey: .replyRoute)
        if let decoded = try container.decodeIfPresent([AgentQuestion].self, forKey: .questions) {
            questions = decoded
        } else {
            let title = try container.decodeIfPresent(String.self, forKey: .title) ?? "Agent needs input"
            let detail = try container.decodeIfPresent(String.self, forKey: .detail)
            let values = try container.decodeIfPresent([String].self, forKey: .options) ?? []
            questions = [AgentQuestion(
                id: "legacy-question",
                prompt: title,
                detail: detail,
                options: values.map { AgentQuestionOption(label: $0) },
                allowsOther: values.isEmpty && kind == .question
            )]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(kind, forKey: .kind)
        try container.encode(provider, forKey: .provider)
        try container.encode(questions, forKey: .questions)
        try container.encode(capability, forKey: .capability)
        try container.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try container.encodeIfPresent(responseContext, forKey: .responseContext)
        try container.encodeIfPresent(replyRoute, forKey: .replyRoute)
    }
}

struct AgentSession: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var agent: AgentKind
    var projectName: String
    var conversationTitle: String
    var activity: LiveActivity
    var capabilities: ProviderCapabilities
    var cwd: String?
    var status: SessionStatus
    var startedAt: Date
    var updatedAt: Date
    var terminalBundleID: String?
    var terminalSessionID: String?
    var threadID: String?
    var eventID: String?
    var interaction: AgentInteraction?
    var model: String?
    var origin: SessionOrigin
    var isProcessAlive: Bool
    var missedProcessPolls: Int
    var processID: Int32?
    var sessionEnded: Bool
    var backingSessionID: String?

    var needsAttention: Bool {
        status == .needsApproval || status == .question || status == .failed
    }

    /// Runtime-only truth used by the active-session count. Persisted rows are
    /// deliberately reset to false on decode so a recent cached "running"
    /// event cannot look like current work after an app relaunch.
    var wasObservedThisLaunch = false

    func isCurrentlyActive(at date: Date = Date()) -> Bool {
        guard wasObservedThisLaunch, !sessionEnded else { return false }
        if interaction != nil || status == .needsApproval || status == .question { return true }
        guard [.running, .waiting].contains(status) else { return false }
        if origin == .process {
            return isProcessAlive && activity.isLive && hasMeaningfulConversationTitle
        }
        if isProcessAlive { return true }
        let age = date.timeIntervalSince(updatedAt)
        if origin == .codexHistory {
            return activity.isLive && age < 20
        }
        guard origin == .hook || origin == .appServer else { return false }
        return age < 20
    }

    /// Compact UI count semantics. A just-observed waiting row is still one
    /// live agent task even when the provider has stopped streaming tokens.
    /// This intentionally follows presentation lifetime rather than the
    /// stricter animation/live-stream predicate above.
    func countsAsActiveTask(at date: Date = Date()) -> Bool {
        guard wasObservedThisLaunch,
              !sessionEnded,
              [.running, .waiting].contains(status) else { return false }
        return isCurrentlyActive(at: date) || shouldPresent(at: date)
    }

    func shouldPresent(at date: Date = Date()) -> Bool {
        if origin == .demo || interaction != nil || status == .needsApproval || status == .question {
            return true
        }
        if sessionEnded { return false }
        // A warm CLI process is not evidence that a chat is doing work.
        // Process-only rows stay available for hook merging, but surface only
        // after a provider supplies a real title and live-turn activity.
        if origin == .process {
            return wasObservedThisLaunch
                && missedProcessPolls < 2
                && activity.isLive
                && hasMeaningfulConversationTitle
        }
        if isProcessAlive { return true }
        if !wasObservedThisLaunch,
           (origin == .hook || origin == .appServer),
           [.running, .waiting].contains(status) {
            return false
        }

        let age = date.timeIntervalSince(updatedAt)
        if status == .completed || status == .failed {
            return age < 90
        }
        switch origin {
        case .hook, .appServer:
            return age < 20
        case .codexHistory:
            return age < 45
        case .process:
            return missedProcessPolls < 2
        case .demo:
            return true
        }
    }

    var displayTitle: String {
        let rawProject = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = ["/", "."].contains(rawProject) ? "" : rawProject
        let title = hasMeaningfulConversationTitle
            ? conversationTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        if project.isEmpty { return title.isEmpty ? agent.displayName : title }
        if title.isEmpty || title.caseInsensitiveCompare(project) == .orderedSame { return project }
        return "\(project) · \(title)"
    }

    var hasMeaningfulConversationTitle: Bool {
        let title = conversationTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        return !["active session", "untitled"].contains(title.lowercased())
    }

    /// Filters legacy host-application metadata out of the optional model slot.
    /// Provider identity is rendered exactly once; labels such as `Codex.app`,
    /// `ChatGPT.app`, or a bundle identifier are not models.
    func canonicalModelLabel(configuredModel: String? = nil) -> String? {
        let reported = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let configured = configuredModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = (reported?.isEmpty == false ? reported : configured),
              !value.isEmpty else { return nil }
        let lower = value.lowercased()
        if lower.hasSuffix(".app")
            || lower.hasPrefix("com.")
            || lower.hasPrefix("app.")
            || lower.contains("chatgpt.app") {
            return nil
        }
        let alphanumeric = lower.filter(\.isLetter)
        let withoutApp = alphanumeric.hasSuffix("app")
            ? String(alphanumeric.dropLast(3))
            : alphanumeric
        let providerKey = agent.displayName.lowercased().filter(\.isLetter)
        if withoutApp == providerKey || withoutApp == agent.rawValue {
            return nil
        }
        return String(value.prefix(24))
    }

    init(
        id: String,
        agent: AgentKind,
        projectName: String,
        conversationTitle: String,
        activity: LiveActivity,
        capabilities: ProviderCapabilities,
        cwd: String?,
        status: SessionStatus,
        startedAt: Date,
        updatedAt: Date,
        terminalBundleID: String?,
        terminalSessionID: String?,
        threadID: String?,
        eventID: String?,
        interaction: AgentInteraction?,
        model: String?,
        origin: SessionOrigin = .hook,
        isProcessAlive: Bool = false,
        missedProcessPolls: Int = 0,
        processID: Int32? = nil,
        sessionEnded: Bool = false,
        backingSessionID: String? = nil
    ) {
        self.id = id
        self.agent = agent
        self.projectName = projectName
        self.conversationTitle = conversationTitle
        self.activity = activity
        self.capabilities = capabilities
        self.cwd = cwd
        self.status = status
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.terminalBundleID = terminalBundleID
        self.terminalSessionID = terminalSessionID
        self.threadID = threadID
        self.eventID = eventID
        self.interaction = interaction
        self.model = model
        self.origin = origin
        self.isProcessAlive = isProcessAlive
        self.missedProcessPolls = missedProcessPolls
        self.processID = processID
        self.sessionEnded = sessionEnded
        self.backingSessionID = backingSessionID
        self.wasObservedThisLaunch = isProcessAlive
    }

    private enum CodingKeys: String, CodingKey {
        case id, agent, projectName, conversationTitle, activity, capabilities, cwd, status
        case startedAt, updatedAt, terminalBundleID, terminalSessionID, threadID, eventID, interaction, model
        case origin, isProcessAlive, missedProcessPolls, processID, sessionEnded, backingSessionID
        case title, detail, project
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        agent = try container.decode(AgentKind.self, forKey: .agent)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        let legacyProject = try container.decodeIfPresent(String.self, forKey: .project)
        projectName = try container.decodeIfPresent(String.self, forKey: .projectName)
            ?? legacyProject
            ?? cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? agent.displayName
        conversationTitle = try container.decodeIfPresent(String.self, forKey: .conversationTitle)
            ?? container.decodeIfPresent(String.self, forKey: .title)
            ?? "Untitled"
        status = try container.decode(SessionStatus.self, forKey: .status)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        let legacyDetail = try container.decodeIfPresent(String.self, forKey: .detail) ?? status.label
        activity = try container.decodeIfPresent(LiveActivity.self, forKey: .activity)
            ?? LiveActivity(phase: Self.phase(for: status), text: legacyDetail, toolName: nil, updatedAt: updatedAt, isLive: false)
        capabilities = try container.decodeIfPresent(ProviderCapabilities.self, forKey: .capabilities)
            ?? .displayOnly
        terminalBundleID = try container.decodeIfPresent(String.self, forKey: .terminalBundleID)
        terminalSessionID = try container.decodeIfPresent(String.self, forKey: .terminalSessionID)
        threadID = try container.decodeIfPresent(String.self, forKey: .threadID)
        eventID = try container.decodeIfPresent(String.self, forKey: .eventID)
        interaction = try? container.decodeIfPresent(AgentInteraction.self, forKey: .interaction)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        origin = try container.decodeIfPresent(SessionOrigin.self, forKey: .origin)
            ?? (agent == .codex ? .codexHistory : .hook)
        // A persisted PID is not proof that a process survived an app restart.
        isProcessAlive = false
        missedProcessPolls = max(2, try container.decodeIfPresent(Int.self, forKey: .missedProcessPolls) ?? 2)
        processID = try container.decodeIfPresent(Int32.self, forKey: .processID)
        sessionEnded = try container.decodeIfPresent(Bool.self, forKey: .sessionEnded) ?? false
        backingSessionID = try container.decodeIfPresent(String.self, forKey: .backingSessionID)
        wasObservedThisLaunch = false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(agent, forKey: .agent)
        try container.encode(projectName, forKey: .projectName)
        try container.encode(conversationTitle, forKey: .conversationTitle)
        try container.encode(activity, forKey: .activity)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encode(status, forKey: .status)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(terminalBundleID, forKey: .terminalBundleID)
        try container.encodeIfPresent(terminalSessionID, forKey: .terminalSessionID)
        try container.encodeIfPresent(threadID, forKey: .threadID)
        try container.encodeIfPresent(eventID, forKey: .eventID)
        try container.encodeIfPresent(interaction, forKey: .interaction)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encode(origin, forKey: .origin)
        try container.encode(isProcessAlive, forKey: .isProcessAlive)
        try container.encode(missedProcessPolls, forKey: .missedProcessPolls)
        try container.encodeIfPresent(processID, forKey: .processID)
        try container.encode(sessionEnded, forKey: .sessionEnded)
        try container.encodeIfPresent(backingSessionID, forKey: .backingSessionID)
    }

    private static func phase(for status: SessionStatus) -> ActivityPhase {
        switch status {
        case .running: .working
        case .waiting: .waiting
        case .needsApproval: .approval
        case .question: .question
        case .completed: .succeeded
        case .failed: .failed
        case .idle: .idle
        }
    }
}

struct NormalizedEvent: Equatable, Sendable {
    var id: String
    var sessionID: String
    var agent: AgentKind
    var eventName: String
    var projectName: String
    var conversationTitle: String?
    var activity: LiveActivity
    var capabilities: ProviderCapabilities
    var cwd: String?
    var status: SessionStatus
    var terminalBundleID: String?
    var terminalSessionID: String?
    var threadID: String?
    var interaction: AgentInteraction?
    var model: String?
    var beginsTurn: Bool
}

enum ModelPreferences {
    static let supportedAgents = AgentIntegrationCatalog.supportedAgents

    static func modelID(for agent: AgentKind) -> String {
        UserDefaults.standard.string(forKey: storageKey(for: agent))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func setModelID(_ value: String, for agent: AgentKind) {
        UserDefaults.standard.set(value, forKey: storageKey(for: agent))
    }

    static func reset() {
        for agent in supportedAgents {
            UserDefaults.standard.removeObject(forKey: storageKey(for: agent))
        }
    }

    static func storageKey(for agent: AgentKind) -> String {
        "notchAgents.model.\(agent.rawValue)"
    }
}
