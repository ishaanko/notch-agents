import AppKit
import Combine
import Foundation

@MainActor
protocol SoundPlaying: AnyObject {
    func play(_ cue: CompletionSoundPlayer.Cue)
}

@MainActor
final class CompletionSoundPlayer: NSObject, NSSoundDelegate, SoundPlaying {
    enum Cue {
        case attention
        case completion

        fileprivate var resourceName: String? {
            switch self {
            case .attention: nil
            case .completion: "CompletionChime"
            }
        }

        fileprivate var filenames: [String] {
            switch self {
            case .attention: ["Glass.aiff", "Ping.aiff"]
            case .completion: ["Glass.aiff", "Ping.aiff"]
            }
        }
    }

    private var playing: [NSSound] = []

    func play(_ cue: Cue) {
        if let resourceName = cue.resourceName,
           let url = Self.soundURL(named: resourceName),
           let sound = NSSound(contentsOf: url, byReference: false) {
            play(sound)
            return
        }
        let sounds = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)
        guard let sound = cue.filenames.lazy.compactMap({ filename in
            NSSound(contentsOf: sounds.appendingPathComponent(filename), byReference: true)
        }).first else {
            NSSound.beep()
            return
        }
        play(sound)
    }

    private func play(_ sound: NSSound) {
        sound.delegate = self
        playing.append(sound)
        if !sound.play() {
            playing.removeAll { $0 === sound }
            NSSound.beep()
        }
    }

    static func soundURL(named name: String) -> URL? {
        let packagedBundle = Bundle.main.resourceURL
            .map { $0.appendingPathComponent("NotchAgents_NotchAgents.bundle") }
            .flatMap(Bundle.init(url:))
        return packagedBundle?.url(
            forResource: name,
            withExtension: "wav",
            subdirectory: "Sounds"
        ) ?? packagedBundle?.url(forResource: name, withExtension: "wav")
            ?? Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "Sounds")
            ?? Bundle.module.url(forResource: name, withExtension: "wav")
    }

    func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        playing.removeAll { $0 === sound }
    }
}

@MainActor
final class SessionStore: ObservableObject {
    private static let maximumResolvedActivityCount = 100
    private static let reservedDiagnosticSessionIDs: Set<String> = [
        "visual-failure", "visual-question", "visual-idle", "visual-working",
    ]
    @Published private(set) var sessions: [AgentSession] = []
    @Published var isExpanded = false
    @Published var isPinned = false
    @Published var selectedSessionID: String?
    @Published var showsAllSessions = false
    @Published private(set) var serverIsReady = false
    @Published private(set) var processMonitorIsReady = false
    @Published private(set) var liveProcessCount = 0
    @Published private(set) var submittedInteractionIDs: Set<String> = []
    @Published private(set) var interactionReplyErrors: [String: String] = [:]
    @Published private(set) var completionTokens: [String: String] = [:]
    @Published private(set) var resolvedActivities: [ResolvedActivity] = []

    private struct PendingReply {
        var interaction: AgentInteraction
        var adapter: any ProviderResponseAdapter
        var completion: ([String: Any]) -> Void
    }

    private var pendingReplies: [String: PendingReply] = [:]
    private var pendingActivity: [String: NormalizedEvent] = [:]
    private var activityTasks: [String: Task<Void, Never>] = [:]
    private var lastActivityPublish: [String: Date] = [:]
    private let persistenceURL: URL
    private var saveTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var collapseGeneration = 0
    private var isPointerInside = false
    private var clearedDiscoveryWatermarks: [String: Date] = [:]
    private var followPreferencesObserver: NSObjectProtocol?
    private let soundPlayer: any SoundPlaying
    private let preferences: UserDefaults
    private let replyTransports: [InteractionReplyTransport: any InteractionReplyTransporting]

    init(
        persistenceURL: URL? = nil,
        soundPlayer: (any SoundPlaying)? = nil,
        preferences: UserDefaults = .standard,
        replyTransports: [InteractionReplyTransport: any InteractionReplyTransporting]? = nil
    ) {
        self.persistenceURL = persistenceURL ?? Self.defaultPersistenceURL
        self.soundPlayer = soundPlayer ?? CompletionSoundPlayer()
        self.preferences = preferences
        self.replyTransports = replyTransports ?? Self.defaultReplyTransports()
        loadClearedDiscoveryWatermarks()
        loadResolvedActivities()
        load()
        followPreferencesObserver = NotificationCenter.default.addObserver(
            forName: .agentFollowPreferencesDidChange,
            object: preferences,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshFollowScope() }
        }
        refreshFollowScope()
        updatePinnedState()
    }

    deinit {
        if let followPreferencesObserver {
            NotificationCenter.default.removeObserver(followPreferencesObserver)
        }
    }

    private static func defaultReplyTransports() -> [
        InteractionReplyTransport: any InteractionReplyTransporting
    ] {
        let credentialStore = T3KeychainAccessTokenStore()
        guard let transport = try? T3ApprovalReplyTransport(
            accessToken: { try credentialStore.accessToken() }
        ) else { return [:] }
        return [.t3Orchestration: transport]
    }

    var visibleSessions: [AgentSession] {
        sessions.filter {
            (isFollowing($0.agent) || hasPendingBlockingReply(for: $0))
                && $0.shouldPresent()
        }
    }

    var activeSessions: [AgentSession] {
        visibleSessions.filter { $0.isCurrentlyActive() }
    }

    var prioritizedCompactSessions: [AgentSession] {
        visibleSessions
    }

    var focusedSession: AgentSession? {
        let visible = visibleSessions
        if let selectedSessionID,
           let selected = visible.first(where: {
               $0.id == selectedSessionID && ($0.interaction != nil || !isPinned)
           }) {
            return selected
        }
        return visible.first(where: { $0.interaction != nil }) ?? visible.first
    }

    var displayedSessions: [AgentSession] {
        showsAllSessions ? visibleSessions : focusedSession.map { [$0] } ?? []
    }

    var attentionCount: Int { visibleSessions.filter(\.needsAttention).count }

    func toggleExpanded() {
        if isExpanded {
            guard !isPinned else { return }
            isExpanded = false
        } else {
            isExpanded = true
        }
    }

    func focusSession(id: String) {
        guard visibleSessions.contains(where: { $0.id == id }) else { return }
        selectedSessionID = id
        showsAllSessions = false
        isExpanded = true
    }

    func moveFocus(by offset: Int) {
        let visible = visibleSessions
        guard visible.count > 1 else { return }
        let currentID = focusedSession?.id
        let currentIndex = visible.firstIndex(where: { $0.id == currentID }) ?? 0
        let nextIndex = (currentIndex + offset + visible.count) % visible.count
        focusSession(id: visible[nextIndex].id)
    }

    func showAllSessions() {
        showsAllSessions = true
        isExpanded = true
    }

    func consumeCompletionToken(for sessionID: String) -> String? {
        completionTokens.removeValue(forKey: sessionID)
    }

    func setServerReady(_ ready: Bool) { serverIsReady = ready }

    func ingest(_ payload: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        if let sessionID = PayloadValue.string(in: payload, keys: [
            "session_id", "sessionId", "conversation_id", "conversationId",
        ]),
           Self.reservedDiagnosticSessionIDs.contains(sessionID) {
            reply(["ok": true, "ignored": true])
            return
        }
        let eventName = PayloadValue.string(in: payload, keys: [
            "hook_event_name", "event_name", "event", "type",
        ])?.lowercased() ?? ""
        if PayloadValue.string(in: payload, keys: ["agent_id"]) != nil,
           !eventName.contains("subagentstart"),
           !eventName.contains("subagentstop") {
            reply(["ok": true])
            return
        }
        let event = EventNormalizer.normalize(payload)
        let hasActionableInteraction =
            event.interaction?.capability.supportsInlineReply == true
        guard isFollowing(event.agent) || hasActionableInteraction else {
            reply(["ok": true, "ignored": true])
            return
        }
        if let interaction = event.interaction,
           interaction.capability.supportsInlineReply {
            apply(event)
            if interaction.capability == .blockingReply {
                pendingReplies[interaction.requestID] = PendingReply(
                    interaction: interaction,
                    adapter: ProviderResponseAdapterRegistry.shared.adapter(for: event.agent),
                    completion: reply
                )
            } else {
                reply(["ok": true, "displayed": true])
            }
            selectedSessionID = event.sessionID
            showsAllSessions = false
            isExpanded = true
            updatePinnedState()
            play(.attention)
            return
        }

        reply(["ok": true])
        publishCoalesced(event)
    }

    func previewCompletionSound() {
        soundPlayer.play(.completion)
    }

    func submitAnswers(sessionID: String, answers: [String: QuestionAnswer]) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              let interaction = sessions[index].interaction,
              interaction.capability.supportsInlineReply,
              !submittedInteractionIDs.contains(interaction.requestID) else { return }

        if interaction.kind == .permission {
            let selected = answers.values.flatMap(\.selectedValues)
            let decision = interaction.questions
                .flatMap(\.options)
                .first(where: { selected.contains($0.value) })?
                .permissionDecision ?? .deny
            let instruction = answers.values.compactMap(\.text)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            if interaction.capability == .transportReply {
                submitTransportReply(
                    sessionID: sessionID,
                    interaction: interaction,
                    decision: decision,
                    instruction: instruction
                )
                return
            }
            guard let pending = pendingReplies.removeValue(forKey: interaction.requestID) else {
                return
            }
            let response = pending.adapter.encodePermission(
                decision,
                instruction: instruction,
                request: interaction
            )
            finishInteraction(sessionID: sessionID, interaction: interaction, decision: decision)
            pending.completion(response)
            return
        }

        guard interaction.capability == .blockingReply,
              let pending = pendingReplies.removeValue(forKey: interaction.requestID) else {
            if interaction.capability == .transportReply {
                submitTransportAnswers(
                    sessionID: sessionID,
                    interaction: interaction,
                    answers: answers
                )
            }
            return
        }
        let response = pending.adapter.encodeAnswers(answers, request: interaction)
        finishInteraction(sessionID: sessionID, interaction: interaction, decision: nil)
        pending.completion(response)
    }

    private func submitTransportReply(
        sessionID: String,
        interaction: AgentInteraction,
        decision: PermissionDecision,
        instruction: String?
    ) {
        guard let route = interaction.replyRoute,
              let transport = replyTransports[route.transport] else {
            let error = InteractionReplyTransportError.unsupportedTransport
            interactionReplyErrors[sessionID] = error.localizedDescription
            recordReplyFailure(
                sessionID: sessionID,
                interaction: interaction,
                error: error
            )
            return
        }
        submittedInteractionIDs.insert(interaction.requestID)
        interactionReplyErrors[sessionID] = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try await transport.respond(
                    to: interaction,
                    decision: decision,
                    instruction: instruction
                )
                self.finishInteraction(
                    sessionID: sessionID,
                    interaction: interaction,
                    decision: decision
                )
            } catch {
                self.submittedInteractionIDs.remove(interaction.requestID)
                self.interactionReplyErrors[sessionID] = error.localizedDescription
                self.recordReplyFailure(
                    sessionID: sessionID,
                    interaction: interaction,
                    error: error
                )
            }
        }
    }

    private func submitTransportAnswers(
        sessionID: String,
        interaction: AgentInteraction,
        answers: [String: QuestionAnswer]
    ) {
        guard let route = interaction.replyRoute,
              let transport = replyTransports[route.transport] else {
            interactionReplyErrors[sessionID] = InteractionReplyTransportError
                .unsupportedTransport.localizedDescription
            recordReplyFailure(
                sessionID: sessionID,
                interaction: interaction,
                error: InteractionReplyTransportError.unsupportedTransport
            )
            return
        }
        submittedInteractionIDs.insert(interaction.requestID)
        interactionReplyErrors[sessionID] = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try await transport.respond(to: interaction, answers: answers)
                self.finishInteraction(
                    sessionID: sessionID,
                    interaction: interaction,
                    decision: nil
                )
            } catch {
                self.submittedInteractionIDs.remove(interaction.requestID)
                self.interactionReplyErrors[sessionID] = error.localizedDescription
                self.recordReplyFailure(
                    sessionID: sessionID,
                    interaction: interaction,
                    error: error
                )
            }
        }
    }

    private func finishInteraction(
        sessionID: String,
        interaction: AgentInteraction,
        decision: PermissionDecision?
    ) {
        guard let index = sessions.firstIndex(where: {
            $0.id == sessionID && $0.interaction?.requestID == interaction.requestID
        }) else {
            submittedInteractionIDs.remove(interaction.requestID)
            return
        }
        let resolvedAt = Date()
        recordResolvedActivity(ResolvedActivity(
            kind: decision == .allow
                ? .accepted
                : decision == .deny ? .declined : .answerSubmitted,
            sessionID: sessionID,
            requestID: interaction.requestID,
            agent: sessions[index].agent,
            projectName: sessions[index].projectName,
            conversationTitle: sessions[index].conversationTitle,
            summary: decision == .allow
                ? "Approval accepted"
                : decision == .deny ? "Approval declined" : "Answer submitted",
            detail: interaction.questions.first?.detail ?? interaction.firstPrompt,
            occurredAt: resolvedAt
        ))
        if let decision {
            sessions[index].activity = LiveActivity(
                phase: decision == .allow ? .working : .waiting,
                text: decision == .allow ? "Approved — continuing" : "Declined — continuing",
                toolName: nil,
                updatedAt: resolvedAt,
                isLive: false
            )
            sessions[index].status = decision == .allow ? .running : .waiting
        } else {
            sessions[index].activity = LiveActivity(
                phase: .working,
                text: "Answer sent — continuing",
                toolName: nil,
                updatedAt: resolvedAt,
                isLive: false
            )
            sessions[index].status = .running
        }
        submittedInteractionIDs.insert(interaction.requestID)
        interactionReplyErrors[sessionID] = nil
        sessions[index].interaction = nil
        sessions[index].updatedAt = resolvedAt
        sortSessions()
        updatePinnedState()
        scheduleSave()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.submittedInteractionIDs.remove(interaction.requestID)
        }
    }

    func jump(to session: AgentSession) { TerminalJumper.jump(to: session) }

    func dismiss(_ sessionID: String) {
        guard !pendingReplies.values.contains(where: { pending in
            sessions.first(where: { $0.id == sessionID })?.interaction?.requestID == pending.interaction.requestID
        }) else { return }
        sessions.removeAll { $0.id == sessionID }
        updatePinnedState()
        scheduleSave()
    }

    func clearCompleted() {
        let clearedAt = Date()
        let removed = sessions.filter {
            [.completed, .failed, .idle].contains($0.status) && $0.interaction == nil
        }
        for session in removed {
            for key in discoveryKeys(for: session) {
                clearedDiscoveryWatermarks[key] = clearedAt
            }
            completionTokens.removeValue(forKey: session.id)
            interactionReplyErrors.removeValue(forKey: session.id)
        }
        pruneClearedDiscoveryWatermarks(at: clearedAt)
        sessions.removeAll { [.completed, .failed, .idle].contains($0.status) && $0.interaction == nil }
        updatePinnedState()
        scheduleSave()
    }

    func clearResolvedActivities() {
        guard !resolvedActivities.isEmpty else { return }
        resolvedActivities.removeAll()
        scheduleSave()
    }

    func addDemoSessions() {
        let samples: [[String: Any]] = [
            [
                "source": "claude", "session_id": "demo-claude", "hook_event_name": "PermissionRequest",
                "conversation_title": "Refactor authentication middleware", "tool_name": "Edit",
                "detail": "Sources/Auth/Middleware.swift", "blocking": true,
            ],
            [
                "source": "codex", "session_id": "demo-codex", "event": "agent_reasoning",
                "conversation_title": "Build the macOS status overlay", "reasoning": "Tuning the notch spring and verifying layer geometry…",
                "cwd": "/Users/demo/NotchAgents",
            ],
            [
                "source": "antigravity", "session_id": "demo-antigravity",
                "event": "Stop", "fullyIdle": true,
                "conversation_title": "Optimize database queries", "message": "3 tests passed",
            ],
        ]
        samples.forEach { payload in ingest(payload) { _ in } }
    }

    func mergeDiscoveredCodexSessions(_ discovered: [DiscoveredSession]) {
        guard isFollowing(.codex) else {
            refreshFollowScope()
            return
        }
        var needsSort = false
        for item in discovered {
            if shouldSuppressCodexDiscovery(item) { continue }
            if let index = sessions.firstIndex(where: {
                $0.id == item.id
                    || $0.threadID == item.threadID
                    || $0.backingSessionID == item.id
                    || $0.backingSessionID == item.threadID
                    || ($0.agent == .codex
                        && $0.origin == .process
                        && $0.threadID == nil
                        && $0.isProcessAlive
                        && $0.cwd == item.cwd)
            }) {
                if sessions[index].agent == .t3code,
                   (sessions[index].backingSessionID == item.id
                    || sessions[index].backingSessionID == item.threadID) {
                    sessions[index].wasObservedThisLaunch = true
                    sessions[index].model = sessions[index].model ?? item.model
                    if item.updatedAt > sessions[index].updatedAt {
                        sessions[index].updatedAt = item.updatedAt
                        needsSort = true
                    }
                    continue
                }
                let previousStatus = sessions[index].status
                let wasActive = sessions[index].isCurrentlyActive()
                let hasBlockingDraft = sessions[index].interaction?.capability.supportsInlineReply == true
                if sessions[index].id.hasPrefix("process:") {
                    sessions[index].id = item.id
                }
                sessions[index].projectName = item.projectName
                sessions[index].conversationTitle = item.conversationTitle
                sessions[index].cwd = item.cwd
                sessions[index].capabilities = item.capabilities
                sessions[index].model = item.model ?? sessions[index].model
                sessions[index].threadID = item.threadID
                sessions[index].terminalBundleID = "com.openai.codex"
                sessions[index].wasObservedThisLaunch = true
                if !sessions[index].isProcessAlive {
                    sessions[index].origin = .codexHistory
                }
                sessions[index].sessionEnded = false
                if !hasBlockingDraft {
                    if sessions[index].activity.phase != item.activity.phase
                        || sessions[index].activity.text != item.activity.text {
                        sessions[index].activity = item.activity
                    }
                    sessions[index].status = item.status
                    sessions[index].interaction = item.interaction
                }
                if wasActive, previousStatus != .completed, item.status == .completed {
                    completionTokens[item.id] = "\(item.id):\(item.updatedAt.timeIntervalSinceReferenceDate)"
                    recordCompletion(for: sessions[index], summary: item.activity.text, at: item.updatedAt)
                    play(.completion)
                }
                if !hasBlockingDraft,
                   sessions[index].updatedAt != item.updatedAt {
                    sessions[index].updatedAt = item.updatedAt
                    needsSort = true
                }
            } else {
                var session = AgentSession(
                    id: item.id,
                    agent: .codex,
                    projectName: item.projectName,
                    conversationTitle: item.conversationTitle,
                    activity: item.activity,
                    capabilities: item.capabilities,
                    cwd: item.cwd,
                    status: item.status,
                    startedAt: item.updatedAt,
                    updatedAt: item.updatedAt,
                    terminalBundleID: "com.openai.codex",
                    terminalSessionID: nil,
                    threadID: item.threadID,
                    eventID: nil,
                    interaction: item.interaction,
                    model: item.model,
                    origin: .codexHistory
                )
                session.wasObservedThisLaunch = true
                sessions.append(session)
                needsSort = true
            }
        }
        if needsSort { sortSessions() }
        updatePinnedState()
        scheduleSave()
    }

    func reconcileProcesses(_ snapshots: [AgentProcessSnapshot]) {
        processMonitorIsReady = true
        liveProcessCount = snapshots.count
        let acceptedSnapshots = snapshots.filter {
            isFollowing($0.agent) && !shouldSuppressT3Discovery($0)
        }
        deduplicateT3BackingSessions(in: acceptedSnapshots)
        var seenIndexes: Set<Int> = []

        for snapshot in acceptedSnapshots {
            let connectedInteraction = snapshot.interaction.flatMap {
                $0.capability.supportsInlineReply ? $0 : nil
            }
            let index = matchingSessionIndex(for: snapshot)
            if let index {
                let previous = sessions[index]
                seenIndexes.insert(index)
                sessions[index].isProcessAlive = true
                sessions[index].wasObservedThisLaunch = true
                sessions[index].missedProcessPolls = 0
                sessions[index].processID = snapshot.processID
                sessions[index].sessionEnded = false
                sessions[index].cwd = snapshot.workingDirectory ?? sessions[index].cwd
                sessions[index].terminalSessionID = snapshot.terminalTTY ?? sessions[index].terminalSessionID
                sessions[index].terminalBundleID = snapshot.terminalBundleID ?? sessions[index].terminalBundleID
                if let projectName = snapshot.projectName, !projectName.isEmpty {
                    sessions[index].projectName = projectName
                }
                if let title = snapshot.conversationTitle, !title.isEmpty {
                    sessions[index].conversationTitle = title
                }
                if let model = snapshot.model, !model.isEmpty {
                    sessions[index].model = model
                }
                if snapshot.agent != .t3code,
                   let interaction = connectedInteraction,
                   sessions[index].interaction?.capability.supportsInlineReply != true {
                    let phase: ActivityPhase = interaction.kind == .question ? .question : .approval
                    sessions[index].interaction = interaction
                    sessions[index].status = SessionStatus(phase: phase)
                    sessions[index].activity = LiveActivity(
                        phase: phase,
                        text: snapshot.activityText ?? interaction.firstPrompt,
                        toolName: nil,
                        updatedAt: Date(),
                        isLive: false
                    )
                } else if snapshot.agent != .t3code,
                          let observedPhase = snapshot.observedPhase,
                          sessions[index].interaction == nil {
                    let observedAt = snapshot.updatedAt ?? Date()
                    sessions[index].status = SessionStatus(phase: observedPhase)
                    sessions[index].activity = LiveActivity(
                        phase: observedPhase,
                        text: snapshot.activityText ?? sessions[index].activity.text,
                        toolName: nil,
                        updatedAt: observedAt,
                        isLive: false
                    )
                    sessions[index].updatedAt = observedAt
                }
                if snapshot.agent == .t3code {
                    let interaction = connectedInteraction.flatMap {
                        submittedInteractionIDs.contains($0.requestID)
                            && previous.interaction == nil ? nil : $0
                    }
                    let phase: ActivityPhase = switch interaction?.kind {
                    case .question: .question
                    case .permission: .approval
                    case nil: snapshot.observedPhase ?? .working
                    }
                    let text = snapshot.activityText ?? previous.activity.text
                    let stateChanged = previous.agent != .t3code
                        || previous.status != SessionStatus(phase: phase)
                        || previous.activity.text != text
                        || previous.interaction != interaction
                    let semanticDate = snapshot.updatedAt
                        ?? (stateChanged ? Date() : previous.updatedAt)
                    let activityDate = max(previous.updatedAt, semanticDate)
                    if let wrapperID = snapshot.sessionID {
                        sessions[index].id = wrapperID
                        sessions[index].threadID = wrapperID
                    }
                    sessions[index].backingSessionID = snapshot.backingSessionID
                    sessions[index].agent = .t3code
                    sessions[index].status = SessionStatus(phase: phase)
                    if stateChanged || semanticDate > previous.updatedAt {
                        sessions[index].activity = LiveActivity(
                            phase: phase,
                            text: text,
                            toolName: nil,
                            updatedAt: activityDate,
                            isLive: interaction == nil
                        )
                        sessions[index].updatedAt = activityDate
                    }
                    sessions[index].interaction = interaction
                    sessions[index].origin = .process
                }
            } else {
                let cwd = snapshot.workingDirectory
                let project = snapshot.projectName
                    ?? cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
                    ?? snapshot.agent.displayName
                let title = snapshot.conversationTitle?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let activityText = snapshot.activityText?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let hasVerifiedLiveTurn = !title.isEmpty && !activityText.isEmpty
                let phase: ActivityPhase = switch connectedInteraction?.kind {
                case .question: .question
                case .permission: .approval
                case nil: snapshot.observedPhase
                    ?? (hasVerifiedLiveTurn ? .working : .waiting)
                }
                let observedAt = snapshot.updatedAt ?? Date()
                sessions.append(AgentSession(
                    id: snapshot.sessionID ?? "process:\(snapshot.agent.rawValue):\(snapshot.processID)",
                    agent: snapshot.agent,
                    projectName: project,
                    conversationTitle: title,
                    activity: LiveActivity(
                        phase: phase,
                        text: hasVerifiedLiveTurn
                            ? activityText
                            : "Connected to \(snapshot.agent.displayName)",
                        toolName: nil,
                        updatedAt: observedAt,
                        isLive: hasVerifiedLiveTurn && connectedInteraction == nil
                    ),
                    capabilities: ProviderEventAdapterRegistry.shared.adapter(for: snapshot.agent).capabilities,
                    cwd: cwd,
                    status: SessionStatus(phase: phase),
                    startedAt: observedAt,
                    updatedAt: observedAt,
                    terminalBundleID: snapshot.terminalBundleID,
                    terminalSessionID: snapshot.terminalTTY,
                    threadID: snapshot.sessionID,
                    eventID: nil,
                    interaction: connectedInteraction,
                    model: snapshot.model,
                    origin: .process,
                    isProcessAlive: true,
                    processID: snapshot.processID,
                    backingSessionID: snapshot.backingSessionID
                ))
                seenIndexes.insert(sessions.count - 1)
            }
        }

        for index in sessions.indices where sessions[index].processID != nil && !seenIndexes.contains(index) {
            sessions[index].missedProcessPolls += 1
            // Keep the row around for one extra poll to avoid visual flicker,
            // but do not describe an unobserved process as currently active.
            sessions[index].isProcessAlive = false
        }

        pruneExpiredSessions()
        sortSessions()
        updatePinnedState()
        scheduleSave()
    }

    var panelHeight: CGFloat {
        let rows = displayedSessions.prefix(5).reduce(CGFloat.zero) { partial, session in
            partial + estimatedRowHeight(for: session)
        }
        let footer = visibleSessions.count > 1 ? NotchTheme.multiSessionFooterHeight : 0
        let minimumHeight: CGFloat = if !showsAllSessions,
                                       let interaction = focusedSession?.interaction {
            interaction.kind == .question
                ? NotchTheme.focusedQuestionMinimumHeight
                : NotchTheme.focusedApprovalMinimumHeight
        } else {
            108
        }
        return min(
            NotchTheme.maximumExpandedHeight,
            max(minimumHeight, 44 + rows + footer + NotchTheme.expandedContentBottomInset)
        )
    }

    private func estimatedRowHeight(for session: AgentSession) -> CGFloat {
        guard let interaction = session.interaction else { return 64 }
        if interaction.kind == .permission {
            let detail = interaction.questions.first?.detail ?? ""
            let lines = max(
                1,
                detail.split(separator: "\n", omittingEmptySubsequences: false).count
            )
            return min(320, max(190, 176 + CGFloat(lines) * 12))
        }
        let optionCount = interaction.questions
            .map { $0.options.count + ($0.allowsOther ? 1 : 0) }
            .max() ?? 0
        return min(330, 126 + CGFloat(optionCount) * 42)
    }

    func setHovered(_ hovered: Bool) {
        isPointerInside = hovered
        hoverTask?.cancel()
        let expandOnHover = preferences.object(
            forKey: "notchAgents.expandOnHover"
        ) as? Bool ?? true
        let hoverDelay = preferences.object(
            forKey: "notchAgents.hoverDelay"
        ) as? Double ?? 0.15
        if hovered {
            collapseGeneration += 1
            collapseTask?.cancel()
            collapseTask = nil
            guard expandOnHover, !isExpanded else { return }
            hoverTask = Task {
                try? await Task.sleep(for: .seconds(max(0, hoverDelay)))
                guard !Task.isCancelled else { return }
                isExpanded = true
            }
        } else {
            scheduleAutoCollapseIfEligible()
        }
    }

    private func publishCoalesced(_ event: NormalizedEvent) {
        let last = lastActivityPublish[event.sessionID] ?? .distantPast
        let isImmediate = sessions.first(where: { $0.id == event.sessionID }) == nil
            || event.beginsTurn
            || event.status == .failed
            || event.status == .completed
            || Date().timeIntervalSince(last) >= 0.08
        guard !isImmediate else {
            pendingActivity[event.sessionID] = nil
            activityTasks[event.sessionID]?.cancel()
            activityTasks[event.sessionID] = nil
            apply(event)
            lastActivityPublish[event.sessionID] = Date()
            return
        }
        pendingActivity[event.sessionID] = event
        guard activityTasks[event.sessionID] == nil else { return }
        let wait = max(0, 0.08 - Date().timeIntervalSince(last))
        activityTasks[event.sessionID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self, let newest = self.pendingActivity.removeValue(forKey: event.sessionID) else {
                return
            }
            self.activityTasks[event.sessionID] = nil
            self.apply(newest)
            self.lastActivityPublish[event.sessionID] = Date()
        }
    }

    private func apply(_ event: NormalizedEvent) {
        let now = Date()
        let matchingIndex = sessions.firstIndex(where: { $0.id == event.sessionID })
            ?? sessions.firstIndex(where: {
                $0.agent == event.agent
                    && $0.origin == .process
                    && $0.threadID == nil
                    && $0.isProcessAlive
                    && event.cwd != nil
                    && $0.cwd == event.cwd
            })
        if let index = matchingIndex {
            let previousStatus = sessions[index].status
            if sessions[index].id.hasPrefix("process:") {
                sessions[index].id = event.sessionID
            }
            sessions[index].agent = event.agent == .unknown ? sessions[index].agent : event.agent
            sessions[index].projectName = event.projectName.isEmpty ? sessions[index].projectName : event.projectName
            if let title = event.conversationTitle, !title.isEmpty {
                sessions[index].conversationTitle = title
            }
            sessions[index].activity = event.activity
            sessions[index].capabilities = event.capabilities
            sessions[index].cwd = event.cwd ?? sessions[index].cwd
            sessions[index].status = event.status
            sessions[index].updatedAt = now
            sessions[index].terminalBundleID = event.terminalBundleID ?? sessions[index].terminalBundleID
            sessions[index].terminalSessionID = event.terminalSessionID ?? sessions[index].terminalSessionID
            sessions[index].threadID = event.threadID ?? sessions[index].threadID
            sessions[index].eventID = event.id
            if let interaction = event.interaction {
                sessions[index].interaction = interaction
            } else if event.status == .completed
                        || event.status == .failed
                        || event.eventName.lowercased().contains("sessionend") {
                interactionReplyErrors[event.sessionID] = nil
                sessions[index].interaction = nil
            }
            sessions[index].model = event.model ?? sessions[index].model
            sessions[index].origin = event.sessionID.hasPrefix("demo-") ? .demo : .hook
            sessions[index].sessionEnded = event.eventName.lowercased().contains("sessionend")
            sessions[index].wasObservedThisLaunch = true
            if previousStatus != .completed, event.status == .completed {
                completionTokens[event.sessionID] = "\(event.sessionID):\(event.id)"
                recordCompletion(for: sessions[index], summary: event.activity.text, at: event.activity.updatedAt)
                play(.completion)
            }
        } else {
            sessions.insert(AgentSession(
                id: event.sessionID,
                agent: event.agent,
                projectName: event.projectName,
                conversationTitle: event.conversationTitle ?? "Untitled",
                activity: event.activity,
                capabilities: event.capabilities,
                cwd: event.cwd,
                status: event.status,
                startedAt: now,
                updatedAt: now,
                terminalBundleID: event.terminalBundleID,
                terminalSessionID: event.terminalSessionID,
                threadID: event.threadID,
                eventID: event.id,
                interaction: event.interaction,
                model: event.model,
                origin: event.sessionID.hasPrefix("demo-") ? .demo : .hook,
                sessionEnded: event.eventName.lowercased().contains("sessionend")
            ), at: 0)
            sessions[0].wasObservedThisLaunch = true
            if event.status == .completed {
                completionTokens[event.sessionID] = "\(event.sessionID):\(event.id)"
                recordCompletion(for: sessions[0], summary: event.activity.text, at: event.activity.updatedAt)
                play(.completion)
            }
        }
        sortSessions()
        updatePinnedState()
        scheduleSave()
    }

    private func updatePinnedState() {
        isPinned = visibleSessions.contains { $0.interaction != nil }
        if isPinned,
           !visibleSessions.contains(where: {
               $0.id == selectedSessionID && $0.interaction != nil
           }) {
            selectedSessionID = visibleSessions.first(where: { $0.interaction != nil })?.id
            showsAllSessions = false
        }
        if !isPinned {
            scheduleAutoCollapseIfEligible()
        }
    }

    private func isFollowing(_ agent: AgentKind) -> Bool {
        AgentFollowPreferences.isFollowing(agent, in: preferences)
    }

    private func hasPendingBlockingReply(for session: AgentSession) -> Bool {
        guard let interaction = session.interaction,
              interaction.capability.supportsInlineReply else { return false }
        return interaction.capability == .transportReply
            || pendingReplies[interaction.requestID] != nil
    }

    private func refreshFollowScope() {
        let removedIDs = sessions.filter {
            !isFollowing($0.agent) && !hasPendingBlockingReply(for: $0)
        }.map(\.id)
        guard !removedIDs.isEmpty else {
            updatePinnedState()
            return
        }
        let removedSet = Set(removedIDs)
        sessions.removeAll { removedSet.contains($0.id) }
        completionTokens = completionTokens.filter { !removedSet.contains($0.key) }
        interactionReplyErrors = interactionReplyErrors.filter {
            !removedSet.contains($0.key)
        }
        if let selectedSessionID, removedSet.contains(selectedSessionID) {
            self.selectedSessionID = nil
        }
        updatePinnedState()
        scheduleSave()
    }

    private func scheduleAutoCollapseIfEligible() {
        let autoCollapse = preferences.object(
            forKey: "notchAgents.autoCollapse"
        ) as? Bool ?? true
        guard autoCollapse,
              isExpanded,
              !isPointerInside,
              !isPinned,
              attentionCount == 0 else { return }
        guard collapseTask == nil else { return }

        collapseGeneration += 1
        let generation = collapseGeneration
        collapseTask = Task {
            try? await Task.sleep(for: .milliseconds(360))
            let stillEnabled = preferences.object(
                forKey: "notchAgents.autoCollapse"
            ) as? Bool ?? true
            if !Task.isCancelled,
               stillEnabled,
               !isPointerInside,
               !isPinned,
               attentionCount == 0 {
                isExpanded = false
            }
            if collapseGeneration == generation {
                collapseTask = nil
            }
        }
    }

    private func sortSessions() {
        sessions = sessions.enumerated().sorted { lhs, rhs in
            if lhs.element.updatedAt != rhs.element.updatedAt {
                return lhs.element.updatedAt > rhs.element.updatedAt
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private func matchingSessionIndex(for snapshot: AgentProcessSnapshot) -> Int? {
        if let backingSessionID = snapshot.backingSessionID,
           let backing = sessions.firstIndex(where: {
               $0.id == backingSessionID
                   || $0.threadID == backingSessionID
                   || $0.backingSessionID == backingSessionID
           }) {
            return backing
        }
        if let sessionID = snapshot.sessionID,
           let exact = sessions.firstIndex(where: {
               $0.id == sessionID || $0.threadID == sessionID || $0.id.hasSuffix(sessionID)
           }) {
            return exact
        }
        if snapshot.sessionID == nil,
           let process = sessions.firstIndex(where: { $0.processID == snapshot.processID }) {
            return process
        }
        if let cwd = snapshot.workingDirectory,
           let contextual = sessions.firstIndex(where: {
               $0.agent == snapshot.agent
                   && $0.cwd == cwd
                   && !$0.sessionEnded
                   && ($0.shouldPresent() || Date().timeIntervalSince($0.updatedAt) < 300)
           }) {
            return contextual
        }
        return nil
    }

    private func pruneExpiredSessions() {
        let now = Date()
        sessions.removeAll { session in
            if session.status == .failed,
               session.interaction == nil,
               now.timeIntervalSince(session.updatedAt) >= 90 {
                return true
            }
            guard session.interaction == nil, !session.shouldPresent(at: now) else { return false }
            return now.timeIntervalSince(session.updatedAt) > 86_400
        }
        if sessions.count > 100 {
            sessions = Array(sessions.sorted { $0.updatedAt > $1.updatedAt }.prefix(100))
        }
    }

    private func deduplicateT3BackingSessions(in snapshots: [AgentProcessSnapshot]) {
        for snapshot in snapshots where snapshot.agent == .t3code {
            guard let wrapperID = snapshot.sessionID,
                  let backingID = snapshot.backingSessionID else { continue }
            let wrapperIndex = sessions.firstIndex {
                $0.id == wrapperID || ($0.agent == .t3code && $0.threadID == wrapperID)
            }
            let codexIndex = sessions.firstIndex {
                $0.agent == .codex && ($0.id == backingID || $0.threadID == backingID)
            }
            if let wrapperIndex, let codexIndex, wrapperIndex != codexIndex {
                let codex = sessions[codexIndex]
                sessions[wrapperIndex].backingSessionID = backingID
                sessions[wrapperIndex].startedAt = min(sessions[wrapperIndex].startedAt, codex.startedAt)
                sessions[wrapperIndex].updatedAt = max(sessions[wrapperIndex].updatedAt, codex.updatedAt)
                sessions[wrapperIndex].model = sessions[wrapperIndex].model ?? codex.model
                sessions.remove(at: codexIndex)
            } else if let wrapperIndex {
                sessions[wrapperIndex].backingSessionID = backingID
            }
        }
    }

    private func discoveryKeys(for session: AgentSession) -> Set<String> {
        var keys: Set<String> = []
        if session.agent == .t3code {
            keys.insert("t3:\(session.id)")
            if let threadID = session.threadID, !threadID.isEmpty {
                keys.insert("t3:\(threadID)")
            }
        }
        if session.agent == .codex {
            keys.insert("codex:\(session.id)")
            if let threadID = session.threadID, !threadID.isEmpty {
                keys.insert("codex:\(threadID)")
            }
        }
        if let backingSessionID = session.backingSessionID, !backingSessionID.isEmpty {
            keys.insert("codex:\(backingSessionID)")
        }
        return keys
    }

    private func shouldSuppressCodexDiscovery(_ item: DiscoveredSession) -> Bool {
        let keys = Set(["codex:\(item.id)", "codex:\(item.threadID)"])
        return shouldSuppressDiscovery(keys: keys, semanticDate: item.updatedAt)
    }

    private func shouldSuppressT3Discovery(_ snapshot: AgentProcessSnapshot) -> Bool {
        guard snapshot.agent == .t3code else { return false }
        var keys: Set<String> = []
        if let sessionID = snapshot.sessionID, !sessionID.isEmpty {
            keys.insert("t3:\(sessionID)")
        }
        if let backingSessionID = snapshot.backingSessionID, !backingSessionID.isEmpty {
            keys.insert("codex:\(backingSessionID)")
        }
        return shouldSuppressDiscovery(keys: keys, semanticDate: snapshot.updatedAt)
    }

    private func shouldSuppressDiscovery(keys: Set<String>, semanticDate: Date?) -> Bool {
        let matched = keys.compactMap { key in
            clearedDiscoveryWatermarks[key].map { (key, $0) }
        }
        guard !matched.isEmpty else { return false }
        guard let semanticDate,
              matched.allSatisfy({ semanticDate > $0.1 }) else {
            return true
        }
        for (key, _) in matched {
            clearedDiscoveryWatermarks.removeValue(forKey: key)
        }
        return false
    }

    private func pruneClearedDiscoveryWatermarks(at now: Date = Date()) {
        clearedDiscoveryWatermarks = clearedDiscoveryWatermarks.filter {
            now.timeIntervalSince($0.value) < 7 * 86_400
        }
        if clearedDiscoveryWatermarks.count > 200 {
            clearedDiscoveryWatermarks = Dictionary(
                uniqueKeysWithValues: clearedDiscoveryWatermarks
                    .sorted { $0.value > $1.value }
                    .prefix(200)
                    .map { ($0.key, $0.value) }
            )
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = sessions
        let resolvedSnapshot = resolvedActivities
        let clearedSnapshot = clearedDiscoveryWatermarks
        let url = persistenceURL
        let resolvedURL = resolvedActivitiesURL
        let clearedURL = clearedDiscoveryWatermarksURL
        saveTask = Task.detached {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder.notchAgents.encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
            if let data = try? JSONEncoder.notchAgents.encode(resolvedSnapshot) {
                try? data.write(to: resolvedURL, options: .atomic)
            }
            if let data = try? JSONEncoder.notchAgents.encode(clearedSnapshot) {
                try? data.write(to: clearedURL, options: .atomic)
            }
        }
    }

    private func play(_ cue: CompletionSoundPlayer.Cue) {
        guard !UserDefaults.standard.bool(forKey: "notchAgents.muted") else { return }
        soundPlayer.play(cue)
    }

    private func load() {
        guard let data = try? Data(contentsOf: persistenceURL),
              let decoded = try? JSONDecoder.notchAgents.decode([AgentSession].self, from: data) else { return }
        sessions = decoded.filter { !Self.reservedDiagnosticSessionIDs.contains($0.id) }
        for index in sessions.indices
        where sessions[index].interaction?.capability.supportsInlineReply != true {
            sessions[index].interaction = nil
            if [.question, .needsApproval].contains(sessions[index].status) {
                sessions[index].status = .waiting
                sessions[index].activity = LiveActivity(
                    phase: .waiting,
                    text: sessions[index].activity.text,
                    toolName: sessions[index].activity.toolName,
                    updatedAt: sessions[index].activity.updatedAt,
                    isLive: false
                )
            }
        }
        if sessions.count != decoded.count {
            scheduleSave()
        }
        pruneExpiredSessions()
        sortSessions()
    }

    private func loadClearedDiscoveryWatermarks() {
        guard let data = try? Data(contentsOf: clearedDiscoveryWatermarksURL),
              let decoded = try? JSONDecoder.notchAgents.decode([String: Date].self, from: data)
        else { return }
        clearedDiscoveryWatermarks = decoded
        pruneClearedDiscoveryWatermarks()
    }

    private func loadResolvedActivities() {
        guard let data = try? Data(contentsOf: resolvedActivitiesURL),
              let decoded = try? JSONDecoder.notchAgents.decode([ResolvedActivity].self, from: data)
        else { return }
        resolvedActivities = Array(
            decoded
                .sorted { $0.occurredAt > $1.occurredAt }
                .prefix(Self.maximumResolvedActivityCount)
        )
    }

    private func recordResolvedActivity(_ activity: ResolvedActivity) {
        resolvedActivities.removeAll { existing in
            existing.kind == activity.kind
                && existing.sessionID == activity.sessionID
                && existing.requestID == activity.requestID
                && abs(existing.occurredAt.timeIntervalSince(activity.occurredAt)) < 1
        }
        resolvedActivities.insert(activity, at: 0)
        if resolvedActivities.count > Self.maximumResolvedActivityCount {
            resolvedActivities.removeLast(
                resolvedActivities.count - Self.maximumResolvedActivityCount
            )
        }
    }

    private func recordReplyFailure(
        sessionID: String,
        interaction: AgentInteraction,
        error: Error
    ) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        recordResolvedActivity(ResolvedActivity(
            kind: .replyFailed,
            sessionID: sessionID,
            requestID: interaction.requestID,
            agent: session.agent,
            projectName: session.projectName,
            conversationTitle: session.conversationTitle,
            summary: interaction.kind == .permission
                ? "Approval reply failed"
                : "Answer reply failed",
            detail: error.localizedDescription
        ))
        scheduleSave()
    }

    private func recordCompletion(
        for session: AgentSession,
        summary: String,
        at date: Date
    ) {
        recordResolvedActivity(ResolvedActivity(
            kind: .completed,
            sessionID: session.id,
            agent: session.agent,
            projectName: session.projectName,
            conversationTitle: session.conversationTitle,
            summary: "Task completed",
            detail: summary,
            occurredAt: date
        ))
    }

    private var resolvedActivitiesURL: URL {
        persistenceURL.appendingPathExtension("resolved-activity")
    }

    private var clearedDiscoveryWatermarksURL: URL {
        persistenceURL.appendingPathExtension("cleared-terminal-sessions")
    }

    private static var defaultPersistenceURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent("NotchAgents/sessions.json")
    }
}

extension JSONEncoder {
    static var notchAgents: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var notchAgents: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
