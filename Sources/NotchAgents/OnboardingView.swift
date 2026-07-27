import AppKit
import SwiftUI

enum OnboardingPreferences {
    static let completedKey = "notchAgents.onboarding.completed"
    static let selectedAgentIDsKey = AgentFollowPreferences.selectedAgentIDsKey

    static func isCompleted(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: completedKey)
    }

    static func selectedAgentIDs(in defaults: UserDefaults = .standard) -> Set<String> {
        AgentFollowPreferences.selectedAgentIDs(in: defaults)
    }

    static func complete(with selectedAgentIDs: Set<String>, in defaults: UserDefaults = .standard) {
        AgentFollowPreferences.setSelectedAgents(
            Set(selectedAgentIDs.compactMap(AgentKind.init(rawValue:))),
            in: defaults
        )
        defaults.set(true, forKey: completedKey)
    }

    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: completedKey)
        AgentFollowPreferences.reset(in: defaults)
    }
}

@MainActor
final class FirstLaunchOnboardingController: NSWindowController, NSWindowDelegate {
    private var completion: (() -> Void)?

    static var shouldPresent: Bool {
        !OnboardingPreferences.isCompleted()
    }

    static var selectedAgentIDs: Set<String> {
        OnboardingPreferences.selectedAgentIDs()
    }

    init(integrations: IntegrationManager, completion: (() -> Void)? = nil) {
        self.completion = completion

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 580),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Notch Agents"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 660, height: 520)
        window.contentView = NSHostingView(
            rootView: OnboardingView(integrations: integrations) { selectedAgentIDs in
                OnboardingPreferences.complete(with: selectedAgentIDs)
                window.close()
            }
        )

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        guard Self.shouldPresent else { return }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        completion?()
        completion = nil
    }
}

struct OnboardingView: View {
    struct AgentOption: Identifiable {
        let id: String
        let displayName: String
        let glyph: String
        let detected: Bool

        init(id: String, displayName: String, glyph: String, detected: Bool) {
            self.id = id
            self.displayName = displayName
            self.glyph = glyph
            self.detected = detected
        }

        init(agent: AgentKind, detected: Bool) {
            self.init(
                id: agent.rawValue,
                displayName: agent.displayName,
                glyph: agent.glyph,
                detected: detected
            )
        }
    }

    @ObservedObject var integrations: IntegrationManager
    let onContinue: (Set<String>) -> Void

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @AppStorage(AppMotionPolicy.animationFPSPreferenceKey) private var animationFPS = 60
    @State private var selectedAgentIDs: Set<String> = []
    @State private var didSeedSelection = false
    @State private var connectionError: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 190), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(options) { option in
                        AgentSelectionCard(
                            option: option,
                            isSelected: selectedAgentIDs.contains(option.id)
                        ) {
                            toggle(option.id)
                        }
                    }
                }
                .padding(24)
            }

            Divider()

            HStack {
                Text(selectionSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Connect & Continue") {
                    connectAndContinue()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(.bar)
        }
        .frame(minWidth: 660, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(
            \.notchReduceMotion,
            AppMotionPolicy.reducesMotion(
                systemPreference: accessibilityReduceMotion,
                animationFPS: animationFPS
            )
        )
        .task {
            integrations.refresh()
            seedSelectionIfNeeded()
        }
        .onChange(of: integrations.integrations.map(\.detected)) {
            seedSelectionIfNeeded()
        }
    }

    private var header: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.gradient)
                    .frame(width: 60, height: 60)
                ThinkingOrb(
                    state: .working,
                    phaseLabel: "Notch Agents",
                    size: 34
                )
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text("Choose your coding agents")
                    .font(.title.weight(.semibold))
                Text(
                    "Select the agents to follow. Notch Agents will connect supported "
                        + "agents so their questions and approvals can be completed in the notch."
                )
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.top, 34)
        .padding(.bottom, 24)
    }

    private var options: [AgentOption] {
        integrations.integrations.map {
            AgentOption(agent: $0.id, detected: $0.detected)
        }
        .sorted {
            if $0.detected != $1.detected { return $0.detected }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private var selectionSummary: String {
        if let connectionError {
            return connectionError
        }
        return switch selectedAgentIDs.count {
        case 0: "You can change this later in Settings."
        case 1: "1 agent selected"
        default: "\(selectedAgentIDs.count) agents selected"
        }
    }

    private func toggle(_ id: String) {
        if selectedAgentIDs.contains(id) {
            selectedAgentIDs.remove(id)
        } else {
            selectedAgentIDs.insert(id)
        }
    }

    private func seedSelectionIfNeeded() {
        guard !didSeedSelection else { return }
        if AgentFollowPreferences.isConfigured() {
            selectedAgentIDs = AgentFollowPreferences.selectedAgentIDs()
        } else {
            selectedAgentIDs = Set(options.filter(\.detected).map(\.id))
        }
        didSeedSelection = true
    }

    private func connectAndContinue() {
        connectionError = nil
        let selectedAgents = Set(selectedAgentIDs.compactMap(AgentKind.init(rawValue:)))
        let failures = integrations.connectSelected(selectedAgents)
        guard failures.isEmpty else {
            connectionError = failures.joined(separator: " · ")
            return
        }
        onContinue(selectedAgentIDs)
    }
}

private struct AgentSelectionCard: View {
    let option: OnboardingView.AgentOption
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.notchReduceMotion) private var appReduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let agent = AgentKind(rawValue: option.id) {
                    AgentBrandIcon(agent: agent, size: 34, role: .company)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(option.displayName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(option.detected ? "Detected on this Mac" : "Supported")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isSelected ? 1.5 : 0.5)
        }
        .animation(selectionAnimation, value: isSelected)
        .accessibilityLabel(option.displayName)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private var selectionAnimation: Animation? {
        accessibilityReduceMotion || appReduceMotion
            ? nil
            : .easeOut(duration: 0.12)
    }
}
