import AppKit
import SwiftUI

struct CompactSessionSummary: Equatable, Sendable {
    var active: Int
    var approvals: Int
    var questions: Int
    var failures: Int

    init(
        active: Int = 0,
        approvals: Int = 0,
        questions: Int = 0,
        failures: Int = 0
    ) {
        self.active = active
        self.approvals = approvals
        self.questions = questions
        self.failures = failures
    }

    init(sessions: [AgentSession], at date: Date = Date()) {
        approvals = sessions.filter { $0.status == .needsApproval }.count
        questions = sessions.filter { $0.status == .question }.count
        failures = sessions.filter { $0.status == .failed }.count
        active = sessions.filter {
            ![.needsApproval, .question, .failed].contains($0.status)
                && $0.countsAsActiveTask(at: date)
        }.count
    }

    var isEmpty: Bool {
        active == 0 && approvals == 0 && questions == 0 && failures == 0
    }

    var accessibilityLabel: String {
        let parts = [
            countLabel(active, singular: "active task", plural: "active tasks"),
            countLabel(approvals, singular: "approval request", plural: "approval requests"),
            countLabel(questions, singular: "question", plural: "questions"),
            countLabel(failures, singular: "failed task", plural: "failed tasks"),
        ].compactMap { $0 }
        return parts.isEmpty ? "No active agent tasks" : parts.joined(separator: ", ")
    }

    private func countLabel(
        _ count: Int,
        singular: String,
        plural: String
    ) -> String? {
        guard count > 0 else { return nil }
        return "\(count) \(count == 1 ? singular : plural)"
    }
}

enum QuestionOptionPresentation {
    static func hoverDescription(
        for option: AgentQuestionOption,
        questionPrompt: String
    ) -> String {
        let detail = option.detail?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let detail, !detail.isEmpty { return detail }
        return "Choose “\(option.label)” for “\(questionPrompt)”"
    }
}

struct NotchEmptyStatePresentation: Equatable, Sendable {
    var symbol: String
    var title: String
    var detail: String
    var actionTitle: String

    static func resolve(
        serverIsReady: Bool,
        processMonitorIsReady: Bool
    ) -> Self {
        if !processMonitorIsReady {
            return Self(
                symbol: "hourglass",
                title: "Starting agent discovery…",
                detail: "Checking this Mac for supported coding agents.",
                actionTitle: "Open Settings"
            )
        }
        if !serverIsReady {
            return Self(
                symbol: "exclamationmark.triangle.fill",
                title: "Local bridge is offline",
                detail: "Agent hooks cannot report activity until it reconnects.",
                actionTitle: "Open Settings"
            )
        }
        return Self(
            symbol: "sparkles",
            title: "No agent activity yet",
            detail: "Start an agent or configure an integration.",
            actionTitle: "Configure Agents"
        )
    }
}

enum NotchSessionListPolicy {
    static func displayedSessions(from sessions: [AgentSession]) -> [AgentSession] {
        sessions
    }
}

enum SessionRelativeTime {
    static func label(since date: Date, relativeTo now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "<1m" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3_600)h" }
        return "\(seconds / 86_400)d"
    }

    static func accessibilityLabel(
        since date: Date,
        relativeTo now: Date = Date()
    ) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "Updated less than one minute ago" }
        if seconds < 3_600 {
            let minutes = seconds / 60
            return "Updated \(minutes) minute\(minutes == 1 ? "" : "s") ago"
        }
        if seconds < 86_400 {
            let hours = seconds / 3_600
            return "Updated \(hours) hour\(hours == 1 ? "" : "s") ago"
        }
        let days = seconds / 86_400
        return "Updated \(days) day\(days == 1 ? "" : "s") ago"
    }
}

struct NotchRootView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var usage: UsageMonitor
    var openSettings: () -> Void
    var quitApplication: () -> Void
    @EnvironmentObject private var motion: NotchSurfaceMotionState
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage(AppMotionPolicy.animationFPSPreferenceKey) private var animationFPS = 60
    @State private var completionBeamToken: String?

    var body: some View {
        ZStack(alignment: .top) {
            CompactNotchView(store: store)
                .opacity(compactOpacity)
                .environment(\.notchAnimationActive, contentProgress < 0.999)
                .allowsHitTesting(contentProgress < 0.5)
                .accessibilityHidden(contentProgress >= 0.5)

            ExpandedNotchView(
                store: store,
                usage: usage,
                openSettings: openSettings,
                quitApplication: quitApplication
            )
                .opacity(expandedProgress)
                .environment(\.notchAnimationActive, contentProgress > 0.001)
                .scaleEffect(
                    shouldReduceMotion ? 1 : 0.97 + 0.03 * expandedProgress,
                    anchor: .top
                )
                .allowsHitTesting(contentProgress >= 0.5)
                .accessibilityHidden(contentProgress < 0.5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .preferredColorScheme(.dark)
        .environment(\.notchReduceMotion, shouldReduceMotion)
        .background(Color.clear)
        .mask(alignment: .top) {
            NotchSurfaceShape(cornerRadius: motion.geometry.cornerRadius)
            .frame(
                width: motion.geometry.width,
                height: motion.geometry.height
            )
        }
        .overlay(alignment: .top) {
            NotchSurfacePerimeter(
                width: motion.geometry.width,
                height: motion.geometry.height,
                cornerRadius: motion.geometry.cornerRadius,
                completionToken: completionBeamToken
            ) {
                completionBeamToken = nil
            }
        }
        .onAppear { consumeNextCompletion() }
        .onChange(of: store.completionTokens) { _, _ in consumeNextCompletion() }
        .onChange(of: completionBeamToken) { _, token in
            if token == nil { consumeNextCompletion() }
        }
    }

    private var compactOpacity: CGFloat {
        1 - contentProgress
    }

    private var expandedProgress: CGFloat {
        contentProgress
    }

    private var contentProgress: CGFloat {
        max(0, min(1, motion.progress))
    }

    private var shouldReduceMotion: Bool {
        motion.reduceMotion || AppMotionPolicy.reducesMotion(
            systemPreference: systemReduceMotion,
            animationFPS: animationFPS
        )
    }

    private func consumeNextCompletion() {
        guard completionBeamToken == nil,
              let sessionID = store.completionTokens.keys.sorted().first,
              let token = store.consumeCompletionToken(for: sessionID) else { return }
        completionBeamToken = token
    }
}

private struct NotchSurfacePerimeter: View {
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    let completionToken: String?
    let completionFinished: () -> Void

    var body: some View {
        Group {
            if let completionToken {
                CompletionBorderBeam(
                    token: completionToken,
                    cornerRadius: cornerRadius,
                    onFinished: completionFinished
                )
            }
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct CompactNotchView: View {
    @ObservedObject var store: SessionStore
    @AppStorage("notchAgents.iconScale") private var iconScale = 1.0

    var body: some View {
        let summary = CompactSessionSummary(sessions: store.visibleSessions)
        Button { store.isExpanded = true } label: {
            HStack(spacing: 6) {
                let visible = Array(store.prioritizedCompactSessions.prefix(2))
                ForEach(visible) { session in
                    ActivityStateImage(
                        phase: session.activity.phase,
                        agent: session.agent,
                        size: NotchTheme.compactIconSize * iconScale
                    )
                }
                if visible.isEmpty {
                    ActivityStateImage(phase: .idle, agent: .unknown, size: NotchTheme.compactIconSize * iconScale)
                        .opacity(0.45)
                }
                Spacer()
                CompactSummaryView(summary: summary)
            }
            .padding(.horizontal, 14)
            .frame(width: NotchTheme.compactWidth, height: NotchTheme.compactHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressablePlainButtonStyle())
        .accessibilityLabel(summary.accessibilityLabel)
        .accessibilityHint("Open Notch Agents")
        .help(summary.accessibilityLabel)
    }
}

private struct CompactSummaryView: View {
    let summary: CompactSessionSummary
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.notchReduceMotion) private var appReduceMotion

    var body: some View {
        HStack(spacing: 7) {
            if summary.active > 0 {
                metric(
                    symbol: "bolt.fill",
                    count: summary.active,
                    label: "active",
                    color: NotchTheme.cyan,
                    help: "Agents currently working or waiting"
                )
            }
            if summary.approvals > 0 {
                metric(
                    symbol: "hand.raised.fill",
                    count: summary.approvals,
                    color: NotchTheme.amber,
                    help: "Approval requests"
                )
            }
            if summary.questions > 0 {
                metric(
                    symbol: "questionmark.bubble.fill",
                    count: summary.questions,
                    color: NotchTheme.amber,
                    help: "Questions awaiting an answer"
                )
            }
            if summary.failures > 0 {
                metric(
                    symbol: "xmark",
                    count: summary.failures,
                    color: NotchTheme.red,
                    help: "Failed agent tasks"
                )
            }
            if summary.isEmpty {
                Text("Idle")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
        .accessibilityHidden(true)
    }

    private func metric(
        symbol: String,
        count: Int,
        label: String? = nil,
        color: Color,
        help: String
    ) -> some View {
        HStack(spacing: 2.5) {
            Image(systemName: symbol)
                .font(.system(size: 7.5, weight: .bold))
            Text("\(count)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(
                    systemReduceMotion || appReduceMotion
                        ? nil
                        : .easeOut(duration: AppMotionPolicy.contentCrossfadeDuration),
                    value: count
                )
            if let label {
                Text(label)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
            }
        }
        .foregroundStyle(color.opacity(0.9))
        .help(help)
    }
}

struct ExpandedNotchView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var usage: UsageMonitor
    var openSettings: () -> Void
    var quitApplication: () -> Void
    @AppStorage("notchAgents.muted") private var isMuted = false
    @AppStorage("notchAgents.showUsage") private var showUsage = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if store.visibleSessions.isEmpty {
                    emptyState
                        .transition(.opacity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(store.displayedSessions) { session in
                                SessionRow(
                                    session: session,
                                    store: store,
                                    isDimmed: store.selectedSessionID != nil
                                        && store.selectedSessionID != session.id
                                        && store.visibleSessions.contains(where: {
                                            $0.interaction != nil
                                        })
                                )
                            }
                        }
                        // Keep the final row above the rounded perimeter and its
                        // glow. The silhouette and the scroll viewport should not
                        // share the same bottom edge.
                        .padding(.bottom, NotchTheme.expandedContentBottomInset)
                    }
                    .scrollIndicators(.automatic)
                    .transition(.opacity)
                }
            }
            .animation(
                .easeOut(duration: AppMotionPolicy.contentCrossfadeDuration),
                value: store.visibleSessions.isEmpty
            )
            if store.visibleSessions.count > 1 {
                multiSessionFooter
            }
        }
        .frame(width: NotchTheme.expandedWidth, height: store.panelHeight, alignment: .top)
        .background(Color.clear)
    }

    private var multiSessionFooter: some View {
        Button {
            store.showsAllSessions.toggle()
        } label: {
            HStack(spacing: 5) {
                Text(
                    store.showsAllSessions
                        ? "Show focused session"
                        : "Show all \(store.visibleSessions.count) sessions"
                )
                Image(systemName: store.showsAllSessions ? "chevron.up" : "chevron.down")
                    .font(.system(size: 7.5, weight: .bold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: NotchTheme.multiSessionFooterHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(SessionDisclosureButtonStyle())
        .accessibilityHint(
            store.showsAllSessions
                ? "Hide background sessions"
                : "Show every running agent session"
        )
    }

    private var header: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(store.serverIsReady ? NotchTheme.lime : NotchTheme.amber)
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
            if showUsage, !usage.windows.isEmpty {
                UsageHeaderView(usage: usage)
                    .layoutPriority(0)
            } else {
                Text(store.activeSessions.isEmpty
                     ? "Waiting for agent activity"
                     : "\(store.activeSessions.count) agent\(store.activeSessions.count == 1 ? "" : "s") active")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.56))
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                HeaderIconButton(
                    systemName: "chevron.up",
                    label: "Collapse Notch Agents",
                    helpText: store.isPinned
                        ? "Respond to the pending request before collapsing"
                        : "Collapse Notch Agents",
                    isEnabled: !store.isPinned
                ) {
                    store.isExpanded = false
                }
                HeaderIconButton(
                    systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    label: isMuted ? "Unmute" : "Mute",
                    helpText: isMuted ? "Unmute sounds" : "Mute sounds"
                ) {
                    isMuted.toggle()
                }
                HeaderIconButton(
                    systemName: "gearshape.fill",
                    label: "Settings",
                    helpText: "Open Settings",
                    action: openSettings
                )
                HeaderIconButton(
                    systemName: "xmark",
                    label: "Quit Notch Agents",
                    helpText: "Quit Notch Agents",
                    action: quitApplication
                )
            }
            .fixedSize()
            .layoutPriority(2)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    private var emptyState: some View {
        let presentation = NotchEmptyStatePresentation.resolve(
            serverIsReady: store.serverIsReady,
            processMonitorIsReady: store.processMonitorIsReady
        )
        return HStack(spacing: 10) {
            Image(systemName: presentation.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(
                    store.processMonitorIsReady && !store.serverIsReady
                        ? NotchTheme.amber
                        : .white.opacity(0.62)
                )
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                Text(presentation.detail)
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer()
            Button(presentation.actionTitle, action: openSettings)
                .buttonStyle(EmptyStateButtonStyle())
        }
        .padding(.horizontal, 19)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

}

private struct UsageHeaderView: View {
    @ObservedObject var usage: UsageMonitor
    @AppStorage(UsageDisplayPreferences.selectedProviderKey)
    private var selectedProviderID = ""
    @AppStorage(UsageDisplayPreferences.pinnedWindowIDsKey)
    private var pinnedWindowIDs = ""

    var body: some View {
        HStack(spacing: 5) {
            if providerIDs.count > 1 {
                HStack(spacing: 1) {
                    ForEach(providerIDs, id: \.self) { providerID in
                        let agent = AgentKind(rawValue: providerID) ?? .unknown
                        Button {
                            selectedProviderID = providerID
                        } label: {
                            AgentBrandIcon(agent: agent, size: 12, role: .company)
                                .foregroundStyle(.white.opacity(
                                    effectiveSelectedProviderID == providerID ? 0.94 : 0.58
                                ))
                                .frame(width: 26, height: 26)
                                .background(
                                    .white.opacity(
                                        effectiveSelectedProviderID == providerID ? 0.12 : 0
                                    ),
                                    in: Circle()
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Show \(BrandIconResolver.providerName(for: agent)) usage")
                        .accessibilityAddTraits(
                            effectiveSelectedProviderID == providerID ? .isSelected : []
                        )
                        .help("Show \(BrandIconResolver.providerName(for: agent)) usage")
                    }
                }
                .padding(2)
                .background(.white.opacity(0.035), in: Capsule())
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) {
                    ForEach(displayedWindows) { meter in
                        UsageMeterView(meter: meter)
                    }
                }
                HStack(spacing: 4) {
                    ForEach(displayedWindows) { meter in
                        UsageMeterView(meter: meter, compact: true)
                    }
                }
            }
        }
    }

    private var providerIDs: [String] {
        var seen: Set<String> = []
        return usage.windows.map(\.agent.rawValue).filter { seen.insert($0).inserted }
    }

    private var effectiveSelectedProviderID: String {
        providerIDs.contains(selectedProviderID) ? selectedProviderID : (providerIDs.first ?? "")
    }

    private var displayedWindows: [UsageWindow] {
        UsageDisplayPreferences.displayedWindows(
            from: usage.windows,
            selectedProviderID: effectiveSelectedProviderID,
            pinnedWindowIDs: UsageDisplayPreferences.pinnedWindowIDs(from: pinnedWindowIDs)
        )
    }
}

private struct UsageMeterView: View {
    let meter: UsageWindow
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            AgentBrandIcon(agent: meter.agent, size: 11, role: .company)
                .foregroundStyle(.white.opacity(0.62))
            Text(meter.windowLabel)
                .foregroundStyle(.white.opacity(0.42))
            Text("\(meter.remainingPercent)% left")
                .fontWeight(.bold)
                .foregroundStyle(remainingColor)
            if !compact, !meter.resetLabel.isEmpty {
                Text(meter.resetLabel)
                    .foregroundStyle(.white.opacity(0.24))
            }
        }
        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, compact ? 5 : 7)
        .padding(.vertical, 4)
        .background(.white.opacity(0.045), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(BrandIconResolver.providerName(for: meter.agent)), \(meter.windowLabel) window, "
                + "\(meter.remainingPercent) percent left"
        )
    }

    private var remainingColor: Color {
        if meter.remainingPercent <= 10 { return NotchTheme.red }
        if meter.remainingPercent <= 35 { return NotchTheme.amber }
        return NotchTheme.lime
    }
}

private struct HeaderIconButton: View {
    let systemName: String
    let label: String
    let helpText: String
    var isEnabled = true
    let action: () -> Void

    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
        }
        .buttonStyle(HeaderIconStyle(isHovered: isHovered, isFocused: isFocused))
        .disabled(!isEnabled)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .accessibilityLabel(label)
        .help(helpText)
    }
}

private struct EmptyStateButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.notchReduceMotion) private var appReduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(isEnabled ? 0.82 : 0.36))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                .white.opacity(configuration.isPressed ? 0.16 : 0.08),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? NotchTheme.pressedScale : 1)
            .animation(
                systemReduceMotion || appReduceMotion ? nil : .easeOut(duration: 0.13),
                value: configuration.isPressed
            )
    }
}

private struct SessionRow: View {
    let session: AgentSession
    @ObservedObject var store: SessionStore
    let isDimmed: Bool
    @AppStorage("notchAgents.showModelBadges") private var showModelBadges = true
    @AppStorage("notchAgents.iconScale") private var iconScale = 1.0
    @AppStorage private var configuredModel: String

    init(session: AgentSession, store: SessionStore, isDimmed: Bool) {
        self.session = session
        _store = ObservedObject(wrappedValue: store)
        self.isDimmed = isDimmed
        _configuredModel = AppStorage(wrappedValue: "", ModelPreferences.storageKey(for: session.agent))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ActivityStateImage(
                phase: session.activity.phase,
                agent: session.agent,
                size: NotchTheme.expandedIconSize * iconScale
            )
            .frame(width: 30, height: 32)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: session.interaction == nil ? 4 : 10) {
                metadataLine
                if let sessionChatTitle {
                    Text(NotchInlineMarkdown.attributed(sessionChatTitle))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                }
                if let interaction = session.interaction {
                    InteractionFlowView(session: session, interaction: interaction, store: store)
                } else {
                    Text(NotchInlineMarkdown.attributed(session.activity.text))
                        .id(session.activity.phase)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(session.isCurrentlyActive() ? 0.52 : 0.38))
                        .lineLimit(2)
                        .lineSpacing(2)
                        .transition(.opacity)
                        .animation(.easeOut(duration: 0.125), value: session.activity.phase)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minHeight: session.interaction == nil ? 58 : nil, alignment: .top)
        .background(
            rowFill,
            in: RoundedRectangle(
                cornerRadius: NotchTheme.sessionCornerRadius,
                style: .continuous
            )
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .opacity(isDimmed ? 0.55 : 1)
        .contextMenu {
            Button("Jump to session") { store.jump(to: session) }
            Button("Dismiss") { store.dismiss(session.id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(sessionProjectName), \(sessionChatTitle.map { "\($0), " } ?? "")"
                + "\(session.activity.phase.accessibilityLabel)"
        )
        .modifier(SessionRowClickFeedback(enabled: session.interaction == nil) {
            store.jump(to: session)
        })
    }

    private var metadataLine: some View {
        HStack(spacing: 7) {
            Text(NotchInlineMarkdown.attributed(sessionProjectName))
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.52))
                .lineLimit(1)
            Spacer(minLength: 8)
            if showModelBadges, let model = modelLabel {
                TagPill(model, color: NotchTheme.identityColor(agent: session.agent, model: model))
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                TagPill(
                    SessionRelativeTime.label(
                        since: session.updatedAt,
                        relativeTo: context.date
                    ),
                    color: .white.opacity(0.42)
                )
                .accessibilityLabel(
                    SessionRelativeTime.accessibilityLabel(
                        since: session.updatedAt,
                        relativeTo: context.date
                    )
                )
            }
        }
    }

    private var sessionProjectName: String {
        let project = session.projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        return project.isEmpty || ["/", "."].contains(project)
            ? session.agent.displayName
            : project
    }

    private var sessionChatTitle: String? {
        guard session.hasMeaningfulConversationTitle else { return nil }
        let title = session.conversationTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || title.caseInsensitiveCompare(sessionProjectName) == .orderedSame {
            return nil
        }
        return title
    }

    private var rowFill: Color {
        if session.interaction != nil { return .white.opacity(0.045) }
        if session.isCurrentlyActive() {
            return NotchTheme.identityColor(
                agent: session.agent,
                model: modelLabel
            ).opacity(0.045)
        }
        return .clear
    }

    private var modelLabel: String? {
        session.canonicalModelLabel(configuredModel: configuredModel)
    }

}

private struct SessionRowClickFeedback: ViewModifier {
    let enabled: Bool
    let action: () -> Void
    @State private var isHovered = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            Button(action: action) {
                content
                    .contentShape(
                        RoundedRectangle(
                            cornerRadius: NotchTheme.sessionCornerRadius,
                            style: .continuous
                        )
                    )
            }
                .buttonStyle(SessionRowPressButtonStyle(isHovered: isHovered))
                .onHover { hovered in
                    isHovered = hovered
                    (hovered ? NSCursor.pointingHand : NSCursor.arrow).set()
                }
                .onDisappear {
                    if isHovered { NSCursor.arrow.set() }
                }
        } else {
            content
        }
    }
}

private struct SessionRowPressButtonStyle: ButtonStyle {
    let isHovered: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.notchReduceMotion) private var appReduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .brightness(configuration.isPressed ? 0.055 : (isHovered ? 0.018 : 0))
            .animation(
                systemReduceMotion || appReduceMotion ? nil : .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
            .animation(
                systemReduceMotion || appReduceMotion ? nil : .easeOut(duration: 0.14),
                value: isHovered
            )
    }
}

private struct InteractionFlowView: View {
    let session: AgentSession
    let interaction: AgentInteraction
    @ObservedObject var store: SessionStore
    @Environment(\.notchReduceMotion) private var reduceMotion
    @State private var step = 0
    @State private var answers: [String: QuestionAnswer] = [:]
    @State private var otherMode = false
    @State private var detailExpanded = false
    @FocusState private var textFieldFocused: Bool

    var body: some View {
        Group {
            if interaction.kind == .permission {
                approvalFlow
            } else {
                questionFlow
            }
        }
        .id(interaction.requestID)
        .transition(
            reduceMotion
                ? .opacity
                : .offset(y: 4).combined(with: .scale(scale: 0.97, anchor: .top)).combined(with: .opacity)
        )
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.16),
            value: interaction.requestID
        )
        .onExitCommand { textFieldFocused = false }
    }

    private var approvalFlow: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 5) {
                Image(systemName: approvalSymbol)
                    .font(.system(size: 9, weight: .bold))
                Text("APPROVAL REQUEST")
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                Spacer()
                Text(session.agent.displayName)
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.28))
            }
            .foregroundStyle(NotchTheme.amber.opacity(0.88))

            HStack(spacing: 6) {
                Label(approvalType, systemImage: approvalSymbol)
                Text("·")
                    .foregroundStyle(.white.opacity(0.18))
                Text(approvalRisk)
                    .foregroundStyle(approvalRiskColor)
            }
            .font(.system(size: 8.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.46))
            .accessibilityLabel(
                "\(session.agent.displayName), \(approvalType), \(approvalRisk)"
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(currentQuestion.prompt)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.84))
                    .fixedSize(horizontal: false, vertical: true)

                if let detail = currentQuestion.detail {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .top, spacing: 6) {
                            Text(detail)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.56))
                                .lineLimit(detailExpanded ? nil : 4)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Button {
                                copyApprovalDetail(detail)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .frame(width: 20, height: 20)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.white.opacity(0.42))
                            .help("Copy approval details")
                            .accessibilityLabel("Copy approval details")
                        }

                        if detailNeedsDisclosure(detail) {
                            Button(detailExpanded ? "Collapse details" : "Show full details") {
                                detailExpanded.toggle()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.44))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(.white.opacity(0.06), lineWidth: 0.5)
                    }
                }
            }

            if let error = store.interactionReplyErrors[session.id] {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(NotchTheme.red.opacity(0.9))
                    Text(error)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.68))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(NotchTheme.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                .transition(
                    reduceMotion
                        ? .opacity
                        : .offset(y: -4).combined(with: .opacity)
                )
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: error)
            }

            if isSubmitting {
                sendingStatus
                    .transition(.opacity)
            } else if otherMode {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Tell the agent what to do instead", text: textBinding, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.84))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 7))
                        .focused($textFieldFocused)
                        .onSubmit { submitInstruction() }

                    HStack(spacing: 6) {
                        Button("Back") {
                            otherMode = false
                            textFieldFocused = false
                        }
                        .buttonStyle(DecisionButtonStyle(primary: false))
                        Spacer()
                        Button("Decline and send instruction") { submitInstruction() }
                            .disabled(!hasText || isSubmitting)
                            .buttonStyle(DecisionButtonStyle(primary: true))
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                HStack(spacing: 6) {
                    Button {
                        submitPermission(.deny)
                    } label: {
                        Text("Decline").frame(maxWidth: .infinity)
                    }
                        .disabled(isSubmitting)
                        .buttonStyle(DecisionButtonStyle(primary: false))
                    if supportsInstruction {
                        Button {
                            otherMode = true
                            textFieldFocused = true
                        } label: {
                            Text("Decline and send instruction…").frame(maxWidth: .infinity)
                        }
                        .disabled(isSubmitting)
                        .buttonStyle(DecisionButtonStyle(primary: false))
                    }
                    Button {
                        submitPermission(.allow)
                    } label: {
                        Text("Accept").frame(maxWidth: .infinity)
                    }
                        .disabled(isSubmitting)
                        .buttonStyle(DecisionButtonStyle(primary: true))
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: detailExpanded)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: otherMode)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isSubmitting)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Approval request: \(currentQuestion.prompt)")
    }

    private var approvalSymbol: String {
        let content = "\(currentQuestion.prompt) \(currentQuestion.detail ?? "")".lowercased()
        if content.contains("remove") || content.contains("delete") {
            return "trash"
        }
        if content.contains("file") || content.contains("patch") || content.contains("edit") {
            return "doc.badge.gearshape"
        }
        return "terminal"
    }

    private var approvalType: String {
        let content = approvalContent
        if content.contains("remove") || content.contains("delete") {
            return "Deletion"
        }
        if content.contains("patch") || content.contains("edit") || content.contains("file") {
            return "File change"
        }
        if content.contains("command") || content.contains("/bin/") || content.contains("shell") {
            return "Command"
        }
        if content.contains("network") || content.contains("url") {
            return "Network access"
        }
        return "Permission"
    }

    private var approvalRisk: String {
        let content = approvalContent
        if ["delete", "remove", "overwrite", "reset --hard", "rm -"].contains(where: content.contains) {
            return "Higher risk"
        }
        if approvalType == "File change" || approvalType == "Command" {
            return "Review required"
        }
        return "Agent request"
    }

    private var approvalRiskColor: Color {
        approvalRisk == "Higher risk"
            ? NotchTheme.red.opacity(0.9)
            : NotchTheme.amber.opacity(0.78)
    }

    private var approvalContent: String {
        "\(currentQuestion.prompt) \(currentQuestion.detail ?? "")".lowercased()
    }

    private var supportsInstruction: Bool {
        interaction.capability == .blockingReply
    }

    private var questionFlow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Label("\(session.agent.questionAskerName) asks", systemImage: "bubble.left.fill")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(NotchTheme.cyan.opacity(0.9))
                if let header = currentQuestion.header {
                    Text("· \(header)")
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.38))
                }
                Spacer()
                if interaction.questions.count > 1 {
                    Text("\(step + 1) / \(interaction.questions.count)")
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.28))
                        .monospacedDigit()
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(currentQuestion.prompt)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = currentQuestion.detail {
                    Text(detail)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.34))
                        .lineLimit(2)
                }
            }
            .id(currentQuestion.id)
            .transition(
                reduceMotion
                    ? .opacity
                    : .asymmetric(insertion: .offset(x: 12).combined(with: .opacity), removal: .offset(x: -12).combined(with: .opacity))
            )
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: step)

            if !currentQuestion.options.isEmpty {
                VStack(spacing: 7) {
                    ForEach(
                        Array(currentQuestion.options.enumerated()),
                        id: \.element.id
                    ) { index, option in
                        Button {
                            select(option)
                        } label: {
                            HStack(spacing: 9) {
                                Text(index < 9 ? "⌘\(index + 1)" : "\(index + 1)")
                                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.88))
                                    .frame(width: 36, height: 27)
                                    .background(
                                        NotchTheme.cyan.opacity(0.34),
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    )
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(option.label)
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                }
                                Spacer(minLength: 8)
                                if selectedValues.contains(option.value) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(NotchTheme.cyan.opacity(0.9))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(
                            QuestionOptionButtonStyle(
                                selected: selectedValues.contains(option.value)
                            )
                        )
                        .modifier(QuestionOptionShortcut(index: index))
                        .help(QuestionOptionPresentation.hoverDescription(
                            for: option,
                            questionPrompt: currentQuestion.prompt
                        ))
                        .accessibilityValue(selectedValues.contains(option.value) ? "Selected" : "Not selected")
                    }
                    if currentQuestion.allowsOther {
                        Button {
                            otherMode = true
                            textFieldFocused = true
                        } label: {
                            HStack(spacing: 9) {
                                Text("\(currentQuestion.options.count + 1)")
                                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.72))
                                    .frame(width: 27, height: 27)
                                    .background(
                                        .white.opacity(0.1),
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    )
                                Text("Other")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(QuestionOptionButtonStyle(selected: otherMode))
                        .help("Write a custom answer for “\(currentQuestion.prompt)”")
                    }
                }
            }

            if currentQuestion.options.isEmpty || otherMode {
                TextField("Type an answer", text: textBinding, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 7))
                    .focused($textFieldFocused)
                    .onSubmit { advanceOrSubmit() }
            }

            if isSubmitting {
                sendingStatus
                    .transition(.opacity)
            } else {
                HStack(spacing: 6) {
                    if step > 0 {
                        Button("Back") { step -= 1; otherMode = hasText }
                            .buttonStyle(DecisionButtonStyle(primary: false))
                    }
                    Spacer()
                    Button(step == interaction.questions.count - 1 ? "Submit" : "Next") {
                        advanceOrSubmit()
                    }
                    .disabled(!isCurrentAnswerValid)
                    .buttonStyle(DecisionButtonStyle(primary: true))
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isSubmitting)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Question \(step + 1) of \(interaction.questions.count): \(currentQuestion.prompt)")
    }

    private var currentQuestion: AgentQuestion {
        interaction.questions[min(max(step, 0), max(0, interaction.questions.count - 1))]
    }

    private var isSubmitting: Bool {
        store.submittedInteractionIDs.contains(interaction.requestID)
    }

    private var sendingStatus: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            Text("Sending…")
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.58))
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sending response")
    }

    private var currentAnswer: QuestionAnswer {
        answers[currentQuestion.id] ?? QuestionAnswer()
    }

    private var selectedValues: [String] { currentAnswer.selectedValues }
    private var hasText: Bool { !(currentAnswer.text?.isEmpty ?? true) }

    private var textBinding: Binding<String> {
        Binding(
            get: { answers[currentQuestion.id]?.text ?? "" },
            set: { value in
                var answer = answers[currentQuestion.id] ?? QuestionAnswer()
                answer.text = value
                answers[currentQuestion.id] = answer
            }
        )
    }

    private var isCurrentAnswerValid: Bool {
        !currentQuestion.required || !currentAnswer.isEmpty
    }

    private func select(_ option: AgentQuestionOption) {
        var answer = currentAnswer
        if currentQuestion.allowsMultiple {
            if let index = answer.selectedValues.firstIndex(of: option.value) {
                answer.selectedValues.remove(at: index)
            } else {
                answer.selectedValues.append(option.value)
            }
        } else {
            answer.selectedValues = [option.value]
            otherMode = false
        }
        answers[currentQuestion.id] = answer
    }

    private func submitPermission(_ decision: PermissionDecision, instruction: String? = nil) {
        let option = currentQuestion.options.first { $0.permissionDecision == decision }
        let selectedValue = option?.value ?? decision.rawValue
        answers[currentQuestion.id] = QuestionAnswer(
            selectedValues: [selectedValue],
            text: instruction
        )
        submitResponse()
    }

    private func submitInstruction() {
        let instruction = currentAnswer.text?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !instruction.isEmpty else { return }
        submitPermission(.deny, instruction: instruction)
    }

    private func advanceOrSubmit() {
        guard isCurrentAnswerValid else { return }
        if step < interaction.questions.count - 1 {
            step += 1
            otherMode = !(answers[currentQuestion.id]?.text?.isEmpty ?? true)
        } else {
            submitResponse()
        }
    }

    private func submitResponse() {
        guard !isSubmitting else { return }
        store.submitAnswers(sessionID: session.id, answers: answers)
    }

    private func copyApprovalDetail(_ detail: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(detail, forType: .string)
    }

    private func detailNeedsDisclosure(_ detail: String) -> Bool {
        detail.count > 180 || detail.split(separator: "\n", omittingEmptySubsequences: false).count > 4
    }
}

enum ActivityStateTone: String, Sendable {
    case active, attention, success, failure, neutral
}

struct ActivityStateEmphasis: Equatable, Sendable {
    var tone: ActivityStateTone
    var glowOpacity: Double
    var iconOpacity: Double

    static func forPhase(_ phase: ActivityPhase) -> ActivityStateEmphasis {
        switch phase {
        case .working, .thinking, .tool, .editing:
            .init(tone: .active, glowOpacity: 0.28, iconOpacity: 1)
        case .question, .approval:
            .init(tone: .attention, glowOpacity: 0.38, iconOpacity: 1)
        case .succeeded:
            .init(tone: .success, glowOpacity: 0.24, iconOpacity: 1)
        case .failed:
            .init(tone: .failure, glowOpacity: 0.42, iconOpacity: 1)
        case .waiting:
            .init(tone: .neutral, glowOpacity: 0.14, iconOpacity: 0.88)
        case .idle:
            .init(tone: .neutral, glowOpacity: 0.10, iconOpacity: 0.76)
        }
    }
}

struct ActivityStateImage: View {
    let phase: ActivityPhase
    let agent: AgentKind
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.notchReduceMotion) private var appReduceMotion
    @Environment(\.notchAnimationActive) private var animationActive

    var body: some View {
        let emphasis = ActivityStateEmphasis.forPhase(phase)
        let reduceMotion = systemReduceMotion || appReduceMotion
        ZStack {
            Circle()
                .fill(semanticColor(emphasis.tone).opacity(emphasis.glowOpacity))
                .frame(width: size * 0.86, height: size * 0.86)
                .blur(radius: size * 0.16)

            Group {
                if let orb = ThinkingOrbState.forActivity(phase),
                   !(reduceMotion && [.question, .approval].contains(phase)) {
                    ThinkingOrb(
                        state: orb,
                        phaseLabel: phase.accessibilityLabel,
                        size: size,
                        paused: !animationActive
                    )
                } else if let image = Self.image(for: phase) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .renderingMode(.template)
                        .foregroundStyle(semanticColor(emphasis.tone).opacity(emphasis.iconOpacity))
                } else {
                    UnknownStatePlaceholder()
                        .foregroundStyle(semanticColor(emphasis.tone).opacity(emphasis.iconOpacity))
                }
            }
        }
        .frame(width: size, height: size)
        .id(phase)
        .transition(.scale(scale: 0.97).combined(with: .opacity))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: phase)
        .accessibilityLabel(phase.accessibilityLabel)
    }

    private func semanticColor(_ tone: ActivityStateTone) -> Color {
        switch tone {
        case .active: NotchTheme.cyan
        case .attention: NotchTheme.amber
        case .success: NotchTheme.lime
        case .failure: NotchTheme.red
        case .neutral: .white
        }
    }

    static func resourceName(for phase: ActivityPhase) -> String {
        switch phase {
        case .working, .thinking: "thinking"
        case .tool: "tool"
        case .editing: "editing"
        case .waiting, .idle: "waiting"
        case .question: "question"
        case .approval: "approval"
        case .succeeded: "success"
        case .failed: "failure"
        }
    }

    @MainActor private static var imageCache: [String: NSImage] = [:]

    @MainActor
    private static func image(for phase: ActivityPhase) -> NSImage? {
        let resourceName = resourceName(for: phase)
        if let cached = imageCache[resourceName] { return cached }
        let packagedBundle = Bundle.main.resourceURL
            .map { $0.appendingPathComponent("NotchAgents_NotchAgents.bundle") }
            .flatMap(Bundle.init(url:))
        guard let url = packagedBundle?.url(
            forResource: resourceName,
            withExtension: "png",
            subdirectory: "ActivityStates"
        ) ?? packagedBundle?.url(forResource: resourceName, withExtension: "png")
            ?? Bundle.module.url(
                forResource: resourceName,
                withExtension: "png",
                subdirectory: "ActivityStates"
            )
            ?? Bundle.module.url(forResource: resourceName, withExtension: "png"),
        let source = NSImage(contentsOf: url),
        let copy = source.copy() as? NSImage else { return nil }
        copy.isTemplate = true
        imageCache[resourceName] = copy
        return copy
    }
}

private struct UnknownStatePlaceholder: View {
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(x: size.width * 0.22, y: size.height * 0.22, width: size.width * 0.56, height: size.height * 0.56)
            context.stroke(Path(roundedRect: rect, cornerRadius: 2), with: .foreground, lineWidth: 1.5)
        }
    }
}

private struct TagPill: View {
    let text: String
    let color: Color
    init(_ text: String, color: Color) { self.text = text; self.color = color }
    var body: some View {
        Text(text)
            .font(.system(size: 8.5, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 5))
            .lineLimit(1)
    }
}

enum NotchInlineMarkdown {
    static func attributed(_ source: String) -> AttributedString {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if let parsed = try? AttributedString(
            markdown: normalized,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            let visible = String(parsed.characters)
            if plainText(visible) == visible {
                return parsed
            }
        }
        return AttributedString(plainText(normalized))
    }

    static func plainText(_ source: String) -> String {
        let characters = Array(source)
        guard !characters.isEmpty else { return "" }
        var result = ""
        result.reserveCapacity(characters.count)

        for index in characters.indices {
            let character = characters[index]
            guard character == "*" || character == "_" || character == "`" else {
                result.append(character)
                continue
            }
            if character == "`" { continue }

            let previous = index > characters.startIndex ? characters[index - 1] : nil
            let next = index < characters.index(before: characters.endIndex)
                ? characters[index + 1]
                : nil
            let touchesWord = previous?.isLetter == true
                || previous?.isNumber == true
                || next?.isLetter == true
                || next?.isNumber == true
            let doublesMarker = previous == character || next == character
            let beginsList = (previous == nil || previous == "\n")
                && next?.isWhitespace == true
            if touchesWord || doublesMarker || beginsList { continue }
            result.append(character)
        }
        return result
    }
}

func agentColor(_ agent: AgentKind) -> Color {
    NotchTheme.identityColor(agent: agent)
}

private struct HeaderIconStyle: ButtonStyle {
    let isHovered: Bool
    let isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.notchReduceMotion) private var appReduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white.opacity(foregroundOpacity(configuration)))
            .frame(width: 30, height: 30)
            .background(
                .white.opacity(backgroundOpacity(configuration)),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.white.opacity(isFocused ? 0.55 : 0), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .scaleEffect(configuration.isPressed ? NotchTheme.pressedScale : 1)
            .animation(buttonAnimation, value: configuration.isPressed)
            .animation(buttonAnimation, value: isHovered)
            .animation(buttonAnimation, value: isFocused)
    }

    private var buttonAnimation: Animation? {
        systemReduceMotion || appReduceMotion ? nil : .easeOut(duration: 0.13)
    }

    private func foregroundOpacity(_ configuration: Configuration) -> Double {
        guard isEnabled else { return 0.28 }
        if configuration.isPressed { return 0.96 }
        return isHovered || isFocused ? 0.88 : 0.7
    }

    private func backgroundOpacity(_ configuration: Configuration) -> Double {
        guard isEnabled else { return 0.025 }
        if configuration.isPressed { return 0.16 }
        return isHovered || isFocused ? 0.1 : 0.045
    }
}

private struct SessionDisclosureButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.notchReduceMotion) private var appReduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.78 : 0.48))
            .background(.black.opacity(0.16))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(
                systemReduceMotion || appReduceMotion
                    ? nil
                    : .easeOut(duration: 0.13),
                value: configuration.isPressed
            )
    }
}

private struct QuestionOptionButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(selected ? 0.94 : 0.76))
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                selected
                    ? NotchTheme.cyan.opacity(configuration.isPressed ? 0.20 : 0.14)
                    : NotchTheme.cyan.opacity(configuration.isPressed ? 0.12 : 0.075),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        selected
                            ? NotchTheme.cyan.opacity(0.3)
                            : Color.white.opacity(0.035),
                        lineWidth: 1
                    )
            }
            .scaleEffect(configuration.isPressed ? NotchTheme.pressedScale : 1)
            .animation(.easeOut(duration: 0.13), value: configuration.isPressed)
    }
}

private struct QuestionOptionShortcut: ViewModifier {
    let index: Int

    @ViewBuilder
    func body(content: Content) -> some View {
        if (0..<9).contains(index) {
            content.keyboardShortcut(
                KeyEquivalent(Character("\(index + 1)")),
                modifiers: .command
            )
        } else {
            content
        }
    }
}

private struct DecisionButtonStyle: ButtonStyle {
    let primary: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(primary ? Color.black : Color.white.opacity(0.72))
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                primary
                    ? Color.white.opacity(isEnabled ? (configuration.isPressed ? 0.68 : 0.9) : 0.3)
                    : Color.white.opacity(configuration.isPressed ? 0.14 : 0.07),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? NotchTheme.pressedScale : 1)
            .animation(.easeOut(duration: 0.13), value: configuration.isPressed)
    }
}

private struct PressablePlainButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.notchReduceMotion) private var appReduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? NotchTheme.pressedScale : 1, anchor: .top)
            .animation(
                systemReduceMotion || appReduceMotion ? nil : .easeOut(duration: 0.13),
                value: configuration.isPressed
            )
    }
}

struct NeonButtonStyle: ButtonStyle {
    var color: Color
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 9 : 10, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, compact ? 9 : 12)
            .padding(.vertical, compact ? 5 : 7)
            .background(color.opacity(configuration.isPressed ? 0.2 : 0.09), in: RoundedRectangle(cornerRadius: 7))
            .scaleEffect(configuration.isPressed ? NotchTheme.pressedScale : 1)
            .animation(.easeOut(duration: 0.13), value: configuration.isPressed)
    }
}
