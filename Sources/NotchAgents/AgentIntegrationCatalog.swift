import Foundation

enum AgentConnectionStyle: Sendable {
    case claudeCompatible
    case codex
    case cursor
    case openCode
    case kimi
    case antigravity
    case runtimeOnly
}

struct AgentIntegrationDescriptor: Sendable {
    var agent: AgentKind
    var configurationPath: String
    var evidencePaths: [String]
    var executableNames: [String]
    var applicationNames: [String]
    var note: String
    var connectionStyle: AgentConnectionStyle

    var canManage: Bool { connectionStyle != .runtimeOnly }
}

/// One authoritative catalog for detection, onboarding, Settings, and models.
///
/// Open Island's ten providers come first. Additional known coding agents are
/// runtime-only until a provider-specific hook/reply contract is verified.
enum AgentIntegrationCatalog {
    static let descriptors: [AgentIntegrationDescriptor] = [
        AgentIntegrationDescriptor(
            agent: .claude,
            configurationPath: ".claude/settings.json",
            evidencePaths: [".claude"],
            executableNames: ["claude"],
            applicationNames: ["Claude.app", "Claude Code.app"],
            note: "Lifecycle · approvals · questions",
            connectionStyle: .claudeCompatible
        ),
        AgentIntegrationDescriptor(
            agent: .codex,
            configurationPath: ".codex/hooks.json",
            evidencePaths: [".codex"],
            executableNames: ["codex"],
            applicationNames: ["Codex.app"],
            note: "Turns · approvals · rollout activity",
            connectionStyle: .codex
        ),
        AgentIntegrationDescriptor(
            agent: .cursor,
            configurationPath: ".cursor/hooks.json",
            evidencePaths: [".cursor"],
            executableNames: ["cursor-agent", "agent-cli"],
            applicationNames: ["Cursor.app"],
            note: "Prompts · shell · MCP · file edits",
            connectionStyle: .cursor
        ),
        AgentIntegrationDescriptor(
            agent: .opencode,
            configurationPath: ".config/opencode/plugins/notch-agents.js",
            evidencePaths: [".config/opencode"],
            executableNames: ["opencode", "opencode-ai"],
            applicationNames: ["OpenCode.app"],
            note: "Sessions · messages · tools",
            connectionStyle: .openCode
        ),
        AgentIntegrationDescriptor(
            agent: .qoder,
            configurationPath: ".qoder/settings.json",
            evidencePaths: [".qoder"],
            executableNames: ["qoder"],
            applicationNames: ["Qoder.app"],
            note: "Claude-compatible lifecycle hooks",
            connectionStyle: .claudeCompatible
        ),
        AgentIntegrationDescriptor(
            agent: .qwen,
            configurationPath: ".qwen/settings.json",
            evidencePaths: [".qwen"],
            executableNames: ["qwen", "qwen-code"],
            applicationNames: ["Qwen Code.app"],
            note: "Claude-compatible lifecycle hooks",
            connectionStyle: .claudeCompatible
        ),
        AgentIntegrationDescriptor(
            agent: .droid,
            configurationPath: ".factory/settings.json",
            evidencePaths: [".factory"],
            executableNames: ["droid"],
            applicationNames: ["Factory.app", "Droid.app"],
            note: "Claude-compatible lifecycle hooks",
            connectionStyle: .claudeCompatible
        ),
        AgentIntegrationDescriptor(
            agent: .codebuddy,
            configurationPath: ".codebuddy/settings.json",
            evidencePaths: [".codebuddy"],
            executableNames: ["codebuddy"],
            applicationNames: ["CodeBuddy.app"],
            note: "Claude-compatible lifecycle hooks",
            connectionStyle: .claudeCompatible
        ),
        AgentIntegrationDescriptor(
            agent: .kimi,
            configurationPath: ".kimi/config.toml",
            evidencePaths: [".kimi"],
            executableNames: ["kimi"],
            applicationNames: ["Kimi.app"],
            note: "Native TOML lifecycle hooks",
            connectionStyle: .kimi
        ),
        AgentIntegrationDescriptor(
            agent: .kiro,
            configurationPath: ".kiro",
            evidencePaths: [".kiro"],
            executableNames: ["kiro", "kiro-cli"],
            applicationNames: ["Kiro.app"],
            note: "Runtime detection",
            connectionStyle: .runtimeOnly
        ),
        AgentIntegrationDescriptor(
            agent: .copilot,
            configurationPath: ".copilot",
            evidencePaths: [".copilot", ".config/github-copilot"],
            executableNames: ["copilot"],
            applicationNames: ["GitHub Copilot.app"],
            note: "Runtime detection",
            connectionStyle: .runtimeOnly
        ),
        AgentIntegrationDescriptor(
            agent: .antigravity,
            configurationPath: ".gemini/antigravity-cli/plugins/notch-agents/hooks.json",
            evidencePaths: [".gemini/antigravity-cli", ".gemini/antigravity"],
            executableNames: ["agy"],
            applicationNames: ["Antigravity.app"],
            note: "Invocations · tools · fully-idle completion",
            connectionStyle: .antigravity
        ),
        AgentIntegrationDescriptor(
            agent: .trae,
            configurationPath: ".trae",
            evidencePaths: [".trae"],
            executableNames: ["trae", "trae-agent"],
            applicationNames: ["Trae.app"],
            note: "Runtime detection",
            connectionStyle: .runtimeOnly
        ),
        AgentIntegrationDescriptor(
            agent: .deepseek,
            configurationPath: ".deepseek",
            evidencePaths: [".deepseek"],
            executableNames: ["codewhale", "codewhale-tui", "deepseek"],
            applicationNames: ["CodeWhale.app", "DeepSeek.app"],
            note: "Runtime detection",
            connectionStyle: .runtimeOnly
        ),
        AgentIntegrationDescriptor(
            agent: .mistral,
            configurationPath: ".vibe",
            evidencePaths: [".vibe"],
            executableNames: ["vibe", "mistral-vibe"],
            applicationNames: ["Mistral Vibe.app", "Vibe.app"],
            note: "Runtime detection",
            connectionStyle: .runtimeOnly
        ),
        AgentIntegrationDescriptor(
            agent: .grok,
            configurationPath: ".grok",
            evidencePaths: [".grok"],
            executableNames: ["grok", "grok-build"],
            applicationNames: ["Grok.app"],
            note: "Runtime detection",
            connectionStyle: .runtimeOnly
        ),
        AgentIntegrationDescriptor(
            agent: .zcode,
            configurationPath: ".zcode",
            evidencePaths: [".zcode"],
            executableNames: ["zcode"],
            applicationNames: ["ZCode.app"],
            note: "Runtime detection",
            connectionStyle: .runtimeOnly
        ),
        AgentIntegrationDescriptor(
            agent: .mimocode,
            configurationPath: ".mimocode",
            evidencePaths: [".mimocode", ".config/mimocode"],
            executableNames: ["mimocode", "mimo-code"],
            applicationNames: ["MiMoCode.app", "MiMo Code.app"],
            note: "Runtime detection",
            connectionStyle: .runtimeOnly
        ),
        AgentIntegrationDescriptor(
            agent: .workbuddy,
            configurationPath: ".workbuddy",
            evidencePaths: [".workbuddy"],
            executableNames: ["workbuddy"],
            applicationNames: ["WorkBuddy.app"],
            note: "Runtime detection",
            connectionStyle: .runtimeOnly
        ),
        AgentIntegrationDescriptor(
            agent: .hermes,
            configurationPath: ".hermes",
            evidencePaths: [".hermes"],
            executableNames: ["hermes", "hermes-agent"],
            applicationNames: ["Hermes.app"],
            note: "Runtime detection",
            connectionStyle: .runtimeOnly
        ),
        AgentIntegrationDescriptor(
            agent: .amp,
            configurationPath: ".config/amp",
            evidencePaths: [".config/amp"],
            executableNames: ["amp"],
            applicationNames: ["Amp.app"],
            note: "Runtime detection",
            connectionStyle: .runtimeOnly
        ),
        AgentIntegrationDescriptor(
            agent: .pi,
            configurationPath: ".pi",
            evidencePaths: [".pi"],
            executableNames: ["pi", "pi-agent"],
            applicationNames: ["Pi Agent.app"],
            note: "Runtime detection",
            connectionStyle: .runtimeOnly
        ),
        AgentIntegrationDescriptor(
            agent: .craft,
            configurationPath: ".craft-agent",
            evidencePaths: [".craft-agent", ".craft"],
            executableNames: ["craft", "craft-agent"],
            applicationNames: ["Craft Agent.app"],
            note: "Runtime detection",
            connectionStyle: .runtimeOnly
        ),
        AgentIntegrationDescriptor(
            agent: .conductor,
            configurationPath: ".conductor",
            evidencePaths: [".conductor"],
            executableNames: ["conductor"],
            applicationNames: ["Conductor.app"],
            note: "Runtime host detection",
            connectionStyle: .runtimeOnly
        ),
        AgentIntegrationDescriptor(
            agent: .t3code,
            configurationPath: ".t3/userdata/state.sqlite",
            evidencePaths: [".t3/userdata/state.sqlite"],
            executableNames: ["t3", "t3code"],
            applicationNames: ["T3 Code.app", "T3 Code (Nightly).app"],
            note: "Live turns from local T3 state",
            connectionStyle: .runtimeOnly
        ),
        AgentIntegrationDescriptor(
            agent: .warp,
            configurationPath: ".warp",
            evidencePaths: [],
            executableNames: ["oz", "warp-agent", "warp_agent"],
            applicationNames: ["Warp.app", "WarpPreview.app"],
            note: "Warp terminal · Oz agent runtime",
            connectionStyle: .runtimeOnly
        ),
    ]

    static let supportedAgents = descriptors.map(\.agent)

    static func descriptor(for agent: AgentKind) -> AgentIntegrationDescriptor? {
        descriptors.first { $0.agent == agent }
    }
}
