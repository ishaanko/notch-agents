import Foundation

enum EventNormalizer {
    static func normalize(_ payload: [String: Any]) -> NormalizedEvent {
        let source = PayloadValue.string(in: payload, keys: ["source", "agent", "provider", "cli"])
        let agent = AgentKind.parse(source)
        let adapter = ProviderEventAdapterRegistry.shared.adapter(for: agent)
        let normalized = adapter.normalize(payload) ?? fallbackEvent(for: agent)
        let sessionID = normalized.sessionID ?? stableFallbackID(payload: payload, source: source)
        let project = normalized.projectName
            ?? normalized.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? agent.displayName
        return NormalizedEvent(
            id: UUID().uuidString,
            sessionID: sessionID,
            agent: agent,
            eventName: normalized.eventName,
            projectName: project,
            conversationTitle: normalized.conversationTitle,
            activity: normalized.activity,
            capabilities: normalized.capabilities,
            cwd: normalized.cwd,
            status: SessionStatus(phase: normalized.activity.phase),
            terminalBundleID: normalized.terminalBundleID,
            terminalSessionID: normalized.terminalSessionID,
            threadID: normalized.threadID,
            interaction: normalized.interaction,
            model: normalized.model,
            beginsTurn: normalized.beginsTurn
        )
    }

    private static func fallbackEvent(for agent: AgentKind) -> ProviderEvent {
        ProviderEvent(
            eventName: "activity",
            sessionID: nil,
            projectName: nil,
            conversationTitle: nil,
            cwd: nil,
            activity: .idle(),
            capabilities: .displayOnly,
            terminalBundleID: nil,
            terminalSessionID: nil,
            threadID: nil,
            interaction: nil,
            model: nil,
            beginsTurn: false
        )
    }

    private static func stableFallbackID(payload: [String: Any], source: String?) -> String {
        let cwd = PayloadValue.string(in: payload, keys: ["cwd", "working_directory"])
            ?? PayloadValue.firstString(in: payload, keys: ["workspacePaths", "workspace_paths"])
            ?? "global"
        return "\(source ?? "agent"):\(cwd)"
    }
}
