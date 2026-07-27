import AppKit
import SwiftUI

struct ResolvedActivityPresentation {
    static func filtered(
        _ activities: [ResolvedActivity],
        query: String
    ) -> [ResolvedActivity] {
        let sorted = activities.sorted { $0.occurredAt > $1.occurredAt }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sorted }

        return sorted.filter { activity in
            [
                label(for: activity.kind),
                activity.agent.displayName,
                activity.projectName,
                activity.conversationTitle,
                activity.summary,
                activity.detail ?? "",
            ]
            .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    static func label(for kind: ResolvedActivityKind) -> String {
        switch kind {
        case .accepted: "Accepted"
        case .declined: "Declined"
        case .answerSubmitted: "Answer Sent"
        case .replyFailed: "Reply Failed"
        case .completed: "Completed"
        }
    }

    static func systemImage(for kind: ResolvedActivityKind) -> String {
        switch kind {
        case .accepted: "checkmark.circle.fill"
        case .declined: "xmark.circle.fill"
        case .answerSubmitted: "paperplane.fill"
        case .replyFailed: "exclamationmark.triangle.fill"
        case .completed: "checkmark.seal.fill"
        }
    }

    static func detail(in activity: ResolvedActivity) -> String? {
        guard let detail = activity.detail?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !detail.isEmpty
        else { return nil }
        return detail
    }

    static func conversationTitle(in activity: ResolvedActivity) -> String? {
        let title = activity.conversationTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let project = activity.projectName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              title.localizedCaseInsensitiveCompare(project) != .orderedSame
        else { return nil }
        return title
    }
}

struct SettingsView: View {
    private enum IntegrationGroup: String, CaseIterable, Identifiable {
        case connected = "Connected"
        case detected = "Detected"
        case notFound = "Not Found"

        var id: Self { self }
    }

    enum Section: String, CaseIterable, Identifiable {
        case general = "General"
        case agents = "Agents"
        case activity = "Activity"
        case models = "Models"
        case updates = "Updates"
        case appearance = "Appearance"
        case sound = "Sound"
        case advanced = "Advanced"

        var id: Self { self }

        var icon: String {
            switch self {
            case .general: "gearshape"
            case .agents: "point.3.connected.trianglepath.dotted"
            case .activity: "clock.arrow.circlepath"
            case .models: "cpu"
            case .updates: "arrow.triangle.2.circlepath"
            case .appearance: "paintpalette"
            case .sound: "speaker.wave.2"
            case .advanced: "slider.horizontal.3"
            }
        }
    }

    @ObservedObject var integrations: IntegrationManager
    @ObservedObject var store: SessionStore
    @ObservedObject var usage: UsageMonitor
    @ObservedObject var updates: UpdateManager

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var selection: Section? = .general
    @State private var modelRevision = 0
    @State private var agentSearch = ""
    @State private var activitySearch = ""
    @State private var showsClearActivityConfirmation = false
    @State private var followedAgents: Set<AgentKind> = []
    @State private var t3PairingCredential = ""
    @State private var t3ConnectionError: String?
    @State private var t3ConnectionInProgress = false
    @State private var t3IsConnected = false
    @AppStorage("notchAgents.expandOnHover") private var expandOnHover = true
    @AppStorage("notchAgents.hoverDelay") private var hoverDelay = 0.15
    @AppStorage("notchAgents.autoCollapse") private var autoCollapse = true
    @AppStorage("notchAgents.showUsage") private var showUsage = true
    @AppStorage("notchAgents.muted") private var muted = false
    @AppStorage("notchAgents.animationFPS") private var animationFPS = 60
    @AppStorage("notchAgents.animationSpeed") private var animationSpeed = 1.0
    @AppStorage("notchAgents.showModelBadges") private var showModelBadges = true
    @AppStorage("notchAgents.iconScale") private var iconScale = 1.0
    @AppStorage("notchAgents.codexReasoning") private var codexReasoning = "Agent default"
    @AppStorage("notchAgents.automaticUpdates") private var automaticUpdates = true
    @AppStorage("notchAgents.updateChannel") private var updateChannel = "Stable"
    @AppStorage("notchAgents.updateFrequency") private var updateFrequency = "Daily"
    @AppStorage(UsageDisplayPreferences.pinnedWindowIDsKey)
    private var pinnedUsageWindowIDs = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 205, max: 240)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, idealWidth: 880, minHeight: 520, idealHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(Section.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
                    .accessibilityLabel("\(section.rawValue) settings")
            }
            .listStyle(.sidebar)

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Label(
                    store.serverIsReady ? "Local bridge online" : "Local bridge offline",
                    systemImage: store.serverIsReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                )
                .foregroundStyle(store.serverIsReady ? Color.green : Color.orange)
                .font(.caption)

                Text(store.processMonitorIsReady
                     ? "\(store.activeSessions.count) active session\(store.activeSessions.count == 1 ? "" : "s")"
                     : "Starting process monitor…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .general {
        case .general: generalPane
        case .agents: agentsPane
        case .activity: activityPane
        case .models: modelsPane
        case .updates: updatesPane
        case .appearance: appearancePane
        case .sound: soundPane
        case .advanced: advancedPane
        }
    }

    private var generalPane: some View {
        SettingsPane(
            title: "General",
            subtitle: "Choose how the notch opens, closes, and animates."
        ) {
            SettingsGroup("Expansion") {
                Toggle("Expand when the pointer enters the notch", isOn: $expandOnHover)
                if expandOnHover {
                    SettingSlider(
                        title: "Hover delay",
                        value: $hoverDelay,
                        range: 0...0.8,
                        step: 0.05,
                        valueLabel: String(format: "%.2f seconds", hoverDelay)
                    )
                    .transition(disclosureTransition)
                }
                Toggle("Collapse when the pointer leaves", isOn: $autoCollapse)
            }
            .animation(.easeOut(duration: 0.15), value: expandOnHover)

            SettingsGroup("Motion") {
                Picker("Refresh rate", selection: $animationFPS) {
                    Text("ProMotion (up to 120 Hz)").tag(120)
                    Text("Balanced (60 Hz)").tag(60)
                    Text("Reduce motion").tag(0)
                }
                if animationFPS != 0 {
                    SettingSlider(
                        title: "Animation speed",
                        value: $animationSpeed,
                        range: 0.65...1.35,
                        step: 0.05,
                        valueLabel: String(format: "%.2f×", animationSpeed)
                    )
                    .transition(disclosureTransition)
                }
                SettingsNote("Transitions synchronize with the active display. ProMotion is used when the display supports it.")
            }
            .animation(.easeOut(duration: 0.15), value: animationFPS)
        }
    }

    private var agentsPane: some View {
        SettingsPane(
            title: "Agents",
            subtitle: "Connect agents so questions and approvals can be completed in the notch."
        ) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search agents", text: $agentSearch)
                    .textFieldStyle(.plain)

                Spacer()

                Button("Refresh") { integrations.refresh() }
                Menu("Follow") {
                    Button("Detected Agents") {
                        setFollowedAgents(
                            Set(integrations.integrations.filter(\.detected).map(\.id))
                        )
                    }
                    Button("All Agents") {
                        setFollowedAgents(Set(integrations.integrations.map(\.id)))
                    }
                    Divider()
                    Button("No Agents") {
                        setFollowedAgents([])
                    }
                }
                Button(integrations.isInstallingAll ? "Connecting…" : "Connect Detected") {
                    integrations.installAll()
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(integrations.isInstallingAll || installableDetectedAgents.isEmpty)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            }

            if let error = integrations.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .textSelection(.enabled)
            }

            if filteredIntegrations.isEmpty {
                ContentUnavailableView.search(text: agentSearch)
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                ForEach(IntegrationGroup.allCases) { group in
                    let items = integrations(in: group)
                    if !items.isEmpty {
                        SettingsGroup(group.rawValue, spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, integration in
                                integrationRow(integration)
                                if index < items.count - 1 {
                                    Divider().padding(.leading, 40)
                                }
                            }
                        }
                    }
                }
            }

            HStack {
                Text("\(followedAgents.count) followed")
                Text("·")
                Text("\(integrations.integrations.filter(\.detected).count) detected")
                if let lastRefreshedAt = integrations.lastRefreshedAt {
                    Text("·")
                    Text("Checked \(lastRefreshedAt, style: .relative)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            SettingsNote(
                "Connect installs a local bridge between the agent and the notch. "
                    + "Only live connector requests become question or approval forms; passive "
                    + "activity observers never create forms they cannot answer."
            )

            SettingsGroup("T3 Code Approvals") {
                HStack {
                    Label(
                        t3IsConnected ? "Connected securely" : "Not connected",
                        systemImage: t3IsConnected ? "checkmark.circle.fill" : "circle.dashed"
                    )
                    .foregroundStyle(t3IsConnected ? Color.green : Color.secondary)

                    Spacer()

                    if t3IsConnected {
                        Button("Disconnect", role: .destructive) {
                            disconnectT3()
                        }
                        .disabled(t3ConnectionInProgress)
                    }
                }

                if !t3IsConnected {
                    VStack(alignment: .leading, spacing: 13) {
                        HStack {
                            SecureField("One-time pairing credential", text: $t3PairingCredential)
                                .textFieldStyle(.roundedBorder)
                                .disabled(t3ConnectionInProgress)
                                .onSubmit { connectT3() }

                            Button(t3ConnectionInProgress ? "Connecting…" : "Connect") {
                                connectT3()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                t3ConnectionInProgress
                                    || t3PairingCredential
                                        .trimmingCharacters(in: .whitespacesAndNewlines)
                                        .isEmpty
                            )
                        }
                        SettingsNote(
                            "Create a one-time pairing credential in T3 Code. "
                                + "Notch Agents exchanges it locally and stores only the scoped access token in Keychain."
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(t3PairingTransition)
                }

                if let error = t3ConnectionError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .textSelection(.enabled)
                        .transition(t3PairingTransition)
                }
            }
            .animation(.easeOut(duration: 0.18), value: t3IsConnected)
            .animation(.easeOut(duration: 0.18), value: t3ConnectionError)
            .onAppear {
                refreshT3ConnectionStatus()
                loadFollowedAgents()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .agentFollowPreferencesDidChange)
            ) { _ in
                followedAgents = AgentFollowPreferences.selectedAgents()
            }
        }
    }

    private var activityPane: some View {
        SettingsPane(
            title: "Recent Activity",
            subtitle: "Review completed work and responses sent through Notch Agents."
        ) {
            if store.resolvedActivities.isEmpty {
                ContentUnavailableView(
                    "No Recent Activity",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(
                        "Completed tasks and resolved approvals or questions will appear here."
                    )
                )
                .frame(maxWidth: .infinity, minHeight: 260)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Search recent activity", text: $activitySearch)
                        .textFieldStyle(.plain)

                    Spacer()

                    Button("Clear History", role: .destructive) {
                        showsClearActivityConfirmation = true
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(
                            Color(nsColor: .separatorColor).opacity(0.5),
                            lineWidth: 0.5
                        )
                }

                if filteredResolvedActivities.isEmpty {
                    ContentUnavailableView.search(text: activitySearch)
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    SettingsGroup("Newest First", spacing: 0) {
                        ForEach(
                            Array(filteredResolvedActivities.enumerated()),
                            id: \.element.id
                        ) { index, activity in
                            RecentActivityRow(activity: activity)
                            if index < filteredResolvedActivities.count - 1 {
                                Divider().padding(.leading, 42)
                            }
                        }
                    }
                }

                SettingsNote(
                    "Recent activity is stored only on this Mac and is separate from live tasks."
                )
            }
        }
        .confirmationDialog(
            "Clear all recent activity?",
            isPresented: $showsClearActivityConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                store.clearResolvedActivities()
                activitySearch = ""
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the local audit history and cannot be undone.")
        }
    }

    private var filteredResolvedActivities: [ResolvedActivity] {
        ResolvedActivityPresentation.filtered(
            store.resolvedActivities,
            query: activitySearch
        )
    }

    private var modelsPane: some View {
        SettingsPane(
            title: "Models",
            subtitle: "Keep model labels consistent and choose the default Codex reasoning effort."
        ) {
            SettingsGroup("Display and Reasoning") {
                Toggle("Show model badges in the notch", isOn: $showModelBadges)
                Picker("Codex reasoning effort", selection: $codexReasoning) {
                    ForEach(["Agent default", "Low", "Medium", "High", "X-High"], id: \.self) {
                        Text($0)
                    }
                }
                SettingsNote("A blank override uses the agent’s own configuration. Hook-reported model IDs always take precedence.")
            }

            SettingsGroup("Model Overrides") {
                ForEach(configurableAgents) { agent in
                    modelRow(agent)
                }
                HStack {
                    Spacer()
                    Button("Reset Overrides", role: .destructive) {
                        ModelPreferences.reset()
                        modelRevision += 1
                    }
                }
            }
            .id(modelRevision)
        }
    }

    private var updatesPane: some View {
        SettingsPane(
            title: "Updates",
            subtitle: "Choose a release channel and when Notch Agents checks for updates."
        ) {
            SettingsGroup("Software Update") {
                HStack(spacing: 14) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Notch Agents \(updates.currentVersion)")
                            .font(.headline)
                        Text(updates.statusText)
                            .font(.callout)
                            .foregroundStyle(updateStatusColor)
                    }
                    Spacer()
                    if case .available = updates.state {
                        Button("Download") { updates.openDownload() }
                    }
                    Button(updates.state == .checking ? "Checking…" : "Check Now") {
                        Task { await updates.check() }
                    }
                    .disabled(updates.state == .checking)
                    .buttonStyle(.borderedProminent)
                }
                if let checked = updates.lastChecked {
                    LabeledContent("Last checked", value: checked.formatted(date: .abbreviated, time: .shortened))
                }
            }

            SettingsGroup("Preferences") {
                Toggle("Automatically check for updates", isOn: $automaticUpdates)
                Picker("Release channel", selection: $updateChannel) {
                    Text("Stable").tag("Stable")
                    Text("Preview").tag("Preview")
                }
                .pickerStyle(.segmented)
                if automaticUpdates {
                    Picker("Check frequency", selection: $updateFrequency) {
                        Text("Daily").tag("Daily")
                        Text("Weekly").tag("Weekly")
                    }
                    .transition(disclosureTransition)
                }
                SettingsNote("Update checks send only the app version to the GitHub Releases API.")
            }
            .animation(.easeOut(duration: 0.15), value: automaticUpdates)
        }
    }

    private var appearancePane: some View {
        SettingsPane(
            title: "Appearance",
            subtitle: "Adjust what appears in the notch and how densely it is presented."
        ) {
            SettingsGroup("Notch") {
                Toggle("Show model badges", isOn: $showModelBadges)
                SettingSlider(
                    title: "Agent icon size",
                    value: $iconScale,
                    range: 0.75...1.15,
                    step: 0.05,
                    valueLabel: "\(Int(iconScale * 100))%"
                )
                LabeledContent("Style", value: "Pure black, content sized")
                LabeledContent("Agent state", value: "Thinking Orbs")
            }

            SettingsGroup("Usage Limits") {
                Toggle("Show usage limits in the header", isOn: $showUsage)
                if showUsage {
                    Group {
                        if usage.windows.isEmpty {
                            SettingsNote("Usage limits appear after a supported provider reports them.")
                        } else {
                            ForEach(usage.windows) { window in
                                HStack(spacing: 10) {
                                    AgentBrandIcon(agent: window.agent, size: 20, role: .company)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(BrandIconResolver.providerName(for: window.agent))
                                        Text("\(window.windowLabel) window · \(window.remainingLabel)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Toggle(
                                        "Always visible",
                                        isOn: pinnedUsageBinding(for: window.id)
                                    )
                                    .toggleStyle(.switch)
                                }
                            }
                            SettingsNote(
                                "Click a provider icon in the notch to switch limits. "
                                    + "Pinned windows stay visible while another provider is selected."
                            )
                        }
                    }
                    .transition(disclosureTransition)
                }
            }
            .animation(.easeOut(duration: 0.15), value: showUsage)
        }
    }

    private var soundPane: some View {
        SettingsPane(
            title: "Sound",
            subtitle: "Use subtle local cues for approvals and completed work."
        ) {
            SettingsGroup("Output") {
                Toggle("Mute all sounds", isOn: $muted)
                SoundPreviewRow(
                    title: "Permission request",
                    sound: "Glass",
                    disabled: muted
                ) {
                    NSSound(named: NSSound.Name("Glass"))?.play()
                }
                SoundPreviewRow(
                    title: "Task complete",
                    sound: "Notch Chime",
                    disabled: muted
                ) {
                    store.previewCompletionSound()
                }
            }
        }
    }

    private var advancedPane: some View {
        SettingsPane(
            title: "Advanced",
            subtitle: "Inspect local services and maintain cached session state."
        ) {
            SettingsGroup("Bridge") {
                LabeledContent("Endpoint", value: "127.0.0.1:18989")
                LabeledContent("Status", value: store.serverIsReady ? "Online" : "Offline")
                LabeledContent("Transport", value: "Loopback HTTP")
                LabeledContent("Privacy", value: "No cloud relay")
            }

            SettingsGroup("Runtime Discovery") {
                LabeledContent("Process monitor", value: store.processMonitorIsReady ? "Online" : "Starting")
                LabeledContent("Live agent processes", value: "\(store.liveProcessCount)")
                SettingsNote("Running processes determine visibility. Integrations add titles, tools, approvals, and questions.")
            }

            SettingsGroup("Session Maintenance") {
                HStack {
                    Text("\(store.sessions.count) cached sessions")
                    Spacer()
                    Button("Clear Finished", role: .destructive) { store.clearCompleted() }
                }
            }
        }
    }

    private var configurableAgents: [AgentKind] {
        let detected = Set(integrations.integrations.filter(\.detected).map(\.id))
        return ModelPreferences.supportedAgents.filter {
            detected.contains($0) || [.codex, .claude, .antigravity, .opencode].contains($0)
        }
    }

    private var filteredIntegrations: [IntegrationManager.Integration] {
        let query = agentSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return integrations.integrations }
        return integrations.integrations.filter {
            $0.id.displayName.localizedCaseInsensitiveContains(query)
                || $0.note.localizedCaseInsensitiveContains(query)
                || integrationStatus($0).localizedCaseInsensitiveContains(query)
        }
    }

    private var installableDetectedAgents: [IntegrationManager.Integration] {
        integrations.integrations.filter {
            $0.canManage && $0.detected && !$0.installed
        }
    }

    private func integrations(
        in group: IntegrationGroup
    ) -> [IntegrationManager.Integration] {
        filteredIntegrations.filter { integration in
            switch group {
            case .connected:
                integration.installed
            case .detected:
                integration.detected && !integration.installed
            case .notFound:
                !integration.detected && !integration.installed
            }
        }
    }

    private func modelRow(_ agent: AgentKind) -> some View {
        LabeledContent {
            TextField("Agent default", text: Binding(
                get: { ModelPreferences.modelID(for: agent) },
                set: { ModelPreferences.setModelID($0, for: agent) }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 180)
        } label: {
            HStack(spacing: 8) {
                AgentBrandIcon(agent: agent, size: 20, role: .company)
                Text(agent.displayName)
            }
        }
    }

    private var updateStatusColor: Color {
        switch updates.state {
        case .available: .green
        case .failed: .red
        default: .secondary
        }
    }

    private func integrationRow(_ integration: IntegrationManager.Integration) -> some View {
        HStack(spacing: 12) {
            AgentBrandIcon(agent: integration.id, size: 28, role: .company)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(integration.id.displayName)
                    .font(.body.weight(.medium))
                Text(integration.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 5) {
                    if integration.capabilities.liveActivity {
                        CapabilityLabel("Live activity")
                    } else if integration.capabilities.eventActivity {
                        CapabilityLabel("Lifecycle events")
                    } else {
                        CapabilityLabel("Runtime presence")
                    }
                    if integration.capabilities.approvals {
                        CapabilityLabel("In-notch approvals")
                    }
                    if integration.capabilities.questions {
                        CapabilityLabel("In-notch questions")
                    }
                    if integration.capabilities.jumpToSession { CapabilityLabel("Open chat") }
                }

                if case let .failed(message) = integrations.operationStates[integration.id] {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 5) {
                operationStatus(for: integration)
                Toggle(
                    "Follow \(integration.id.displayName)",
                    isOn: followBinding(for: integration.id)
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(
                    followedAgents.contains(integration.id)
                        ? "Stop following \(integration.id.displayName)"
                        : "Follow \(integration.id.displayName)"
                )
            }

            if integration.canManage {
                Button(integration.installed ? "Disconnect" : installButtonTitle(for: integration)) {
                    if integration.installed {
                        integrations.uninstall(integration.id)
                    } else {
                        integrations.install(integration.id)
                    }
                }
                .disabled(
                    (!integration.detected && !integration.installed)
                        || integrations.operationStates[integration.id] == .installing
                )
            }
        }
        .padding(.vertical, 10)
    }

    private func integrationStatus(_ integration: IntegrationManager.Integration) -> String {
        if integration.isRuntimeOnly {
            return integration.detected ? "Automatic" : "Not found"
        }
        return integration.installed ? "Connected" : (integration.detected ? "Detected" : "Not found")
    }

    @ViewBuilder
    private func operationStatus(
        for integration: IntegrationManager.Integration
    ) -> some View {
        switch integrations.operationStates[integration.id] {
        case .installing:
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.small)
                Text("Connecting")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .failed:
            Label("Connection failed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        case .succeeded, .none:
            Text(integrationStatus(integration))
                .font(.caption)
                .foregroundStyle(integration.installed ? Color.green : Color.secondary)
        }
    }

    private func installButtonTitle(
        for integration: IntegrationManager.Integration
    ) -> String {
        if integrations.operationStates[integration.id] == .installing {
            return "Connecting…"
        }
        if case .failed = integrations.operationStates[integration.id] {
            return "Retry"
        }
        return "Connect"
    }

    private func loadFollowedAgents() {
        followedAgents = AgentFollowPreferences.initializeIfNeeded(
            detectedAgents: Set(integrations.integrations.filter(\.detected).map(\.id))
        )
    }

    private func setFollowedAgents(_ agents: Set<AgentKind>) {
        followedAgents = agents
        AgentFollowPreferences.setSelectedAgents(agents)
    }

    private func followBinding(for agent: AgentKind) -> Binding<Bool> {
        Binding(
            get: { followedAgents.contains(agent) },
            set: { isFollowing in
                var updated = followedAgents
                if isFollowing {
                    updated.insert(agent)
                } else {
                    updated.remove(agent)
                }
                setFollowedAgents(updated)
            }
        )
    }

    private var disclosureTransition: AnyTransition {
        reducesSettingsMotion
            ? .opacity
            : .opacity.combined(with: .offset(y: -4))
    }

    private var t3PairingTransition: AnyTransition {
        reducesSettingsMotion
            ? .opacity
            : .opacity.combined(with: .offset(y: 4))
    }

    private var reducesSettingsMotion: Bool {
        AppMotionPolicy.reducesMotion(
            systemPreference: accessibilityReduceMotion,
            animationFPS: animationFPS
        )
    }

    private func refreshT3ConnectionStatus() {
        do {
            _ = try T3KeychainAccessTokenStore().accessToken()
            t3IsConnected = true
            t3ConnectionError = nil
        } catch T3AccessTokenError.missing {
            t3IsConnected = false
        } catch {
            t3IsConnected = false
            t3ConnectionError = error.localizedDescription
        }
    }

    private func connectT3() {
        let credential = t3PairingCredential
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty, !t3ConnectionInProgress else { return }

        // Do not retain the one-time credential in view state while it is exchanged.
        t3PairingCredential.removeAll(keepingCapacity: false)
        t3ConnectionInProgress = true
        t3ConnectionError = nil

        Task { @MainActor in
            defer { t3ConnectionInProgress = false }
            do {
                let exchanger = try T3PairingCredentialExchanger()
                let accessToken = try await exchanger.exchange(credential)
                try T3KeychainAccessTokenStore().save(accessToken)
                t3IsConnected = true
            } catch {
                t3IsConnected = false
                t3ConnectionError = error.localizedDescription
            }
        }
    }

    private func disconnectT3() {
        do {
            try T3KeychainAccessTokenStore().remove()
            t3IsConnected = false
            t3ConnectionError = nil
            t3PairingCredential.removeAll(keepingCapacity: false)
        } catch {
            t3ConnectionError = error.localizedDescription
        }
    }

    private func pinnedUsageBinding(for windowID: String) -> Binding<Bool> {
        Binding(
            get: {
                UsageDisplayPreferences.pinnedWindowIDs(from: pinnedUsageWindowIDs)
                    .contains(windowID)
            },
            set: { pinned in
                var ids = UsageDisplayPreferences.pinnedWindowIDs(from: pinnedUsageWindowIDs)
                if pinned {
                    if !ids.contains(windowID) { ids.append(windowID) }
                } else {
                    ids.removeAll { $0 == windowID }
                }
                pinnedUsageWindowIDs = UsageDisplayPreferences.rawValue(for: ids)
            }
        )
    }
}

private struct CapabilityLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }
}

private struct RecentActivityRow: View {
    let activity: ResolvedActivity

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @AppStorage(AppMotionPolicy.animationFPSPreferenceKey) private var animationFPS = 60
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if detail != nil {
                Button {
                    isExpanded.toggle()
                } label: {
                    summaryRow
                }
                .buttonStyle(.plain)
                .accessibilityHint(isExpanded ? "Collapse details" : "Show details")
            } else {
                summaryRow
            }

            if isExpanded, let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 9)
                    .padding(.leading, 42)
                    .padding(.trailing, 8)
                    .transition(detailTransition)
                    .accessibilityLabel("Details")
                    .accessibilityValue(detail)
            }
        }
        .padding(.vertical, 11)
        .animation(detailAnimation, value: isExpanded)
    }

    private var summaryRow: some View {
        HStack(alignment: .top, spacing: 12) {
            AgentBrandIcon(agent: activity.agent, size: 30, role: .company)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(activity.projectName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if let conversationTitle {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(conversationTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Text(activity.summary)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 4) {
                Label(
                    ResolvedActivityPresentation.label(for: activity.kind),
                    systemImage: ResolvedActivityPresentation.systemImage(for: activity.kind)
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(kindColor)

                HStack(spacing: 4) {
                    Text(activity.occurredAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if detail != nil {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var detail: String? {
        ResolvedActivityPresentation.detail(in: activity)
    }

    private var conversationTitle: String? {
        ResolvedActivityPresentation.conversationTitle(in: activity)
    }

    private var reducesMotion: Bool {
        AppMotionPolicy.reducesMotion(
            systemPreference: accessibilityReduceMotion,
            animationFPS: animationFPS
        )
    }

    private var detailAnimation: Animation? {
        reducesMotion ? nil : .easeOut(duration: 0.15)
    }

    private var detailTransition: AnyTransition {
        reducesMotion ? .opacity : .opacity.combined(with: .offset(y: -4))
    }

    private var kindColor: Color {
        switch activity.kind {
        case .accepted, .completed: .green
        case .declined: .orange
        case .answerSubmitted: .accentColor
        case .replyFailed: .red
        }
    }
}

private struct SettingsPane<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.largeTitle.weight(.semibold))
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                content
            }
            .frame(maxWidth: 700, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    let spacing: CGFloat
    @ViewBuilder let content: Content

    init(_ title: String, spacing: CGFloat = 13, @ViewBuilder content: () -> Content) {
        self.title = title
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: spacing) {
                content
            }
            .controlSize(.regular)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
            }
        }
    }
}

private struct SettingSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let valueLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            LabeledContent(title, value: valueLabel)
            Slider(value: $value, in: range, step: step)
        }
    }
}

private struct SoundPreviewRow: View {
    let title: String
    let sound: String
    let disabled: Bool
    let preview: () -> Void

    var body: some View {
        HStack {
            LabeledContent(title, value: sound)
            Button(action: preview) {
                Label("Preview", systemImage: "play.fill")
            }
            .disabled(disabled)
        }
    }
}

private struct SettingsNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
