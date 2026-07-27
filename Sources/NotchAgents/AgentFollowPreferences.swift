import Foundation

extension Notification.Name {
    static let agentFollowPreferencesDidChange = Notification.Name(
        "notchAgents.agentFollowPreferencesDidChange"
    )
}

/// The single durable source of truth for which agents Notch Agents follows.
///
/// A missing value means the user has not chosen yet. An empty stored array is
/// intentional and means no agents should be followed.
enum AgentFollowPreferences {
    static let selectedAgentIDsKey = "notchAgents.onboarding.selectedAgentIDs"

    static func isConfigured(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: selectedAgentIDsKey) != nil
    }

    static func selectedAgents(in defaults: UserDefaults = .standard) -> Set<AgentKind> {
        Set(
            (defaults.stringArray(forKey: selectedAgentIDsKey) ?? [])
                .compactMap(AgentKind.init(rawValue:))
                .filter { $0 != .unknown }
        )
    }

    static func selectedAgentIDs(in defaults: UserDefaults = .standard) -> Set<String> {
        Set(selectedAgents(in: defaults).map(\.rawValue))
    }

    /// Preserves pre-onboarding behavior until a choice is stored. Once
    /// configured, including with an empty selection, the stored scope wins.
    static func isFollowing(
        _ agent: AgentKind,
        in defaults: UserDefaults = .standard
    ) -> Bool {
        guard isConfigured(in: defaults) else { return true }
        return selectedAgents(in: defaults).contains(agent)
    }

    @discardableResult
    static func initializeIfNeeded(
        detectedAgents: Set<AgentKind>,
        in defaults: UserDefaults = .standard
    ) -> Set<AgentKind> {
        guard !isConfigured(in: defaults) else {
            return selectedAgents(in: defaults)
        }
        let initial = Set(detectedAgents.filter { $0 != .unknown })
        setSelectedAgents(initial, in: defaults)
        return initial
    }

    static func setSelectedAgents(
        _ agents: Set<AgentKind>,
        in defaults: UserDefaults = .standard
    ) {
        let ids = agents
            .filter { $0 != .unknown }
            .map(\.rawValue)
            .sorted()
        defaults.set(ids, forKey: selectedAgentIDsKey)
        NotificationCenter.default.post(
            name: .agentFollowPreferencesDidChange,
            object: defaults,
            userInfo: ["selectedAgentIDs": ids]
        )
    }

    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: selectedAgentIDsKey)
        NotificationCenter.default.post(
            name: .agentFollowPreferencesDidChange,
            object: defaults
        )
    }
}
