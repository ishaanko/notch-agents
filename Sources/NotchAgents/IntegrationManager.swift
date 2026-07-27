import Foundation

@MainActor
final class IntegrationManager: ObservableObject {
    enum OperationState: Equatable {
        case installing
        case succeeded
        case failed(String)
    }

    struct Integration: Identifiable {
        var id: AgentKind
        var configURL: URL
        var installed: Bool
        var detected: Bool
        var note: String
        var capabilities: ProviderCapabilities
        var canManage: Bool

        var isRuntimeOnly: Bool { !canManage }
    }

    @Published private(set) var integrations: [Integration] = []
    @Published var lastError: String?
    @Published private(set) var operationStates: [AgentKind: OperationState] = [:]
    @Published private(set) var isInstallingAll = false
    @Published private(set) var lastRefreshedAt: Date?

    private let fileManager: FileManager
    private let home: URL

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.home = home
        self.fileManager = fileManager
        refresh()
    }

    func refresh() {
        integrations = AgentIntegrationCatalog.descriptors.map(integration)
        lastRefreshedAt = Date()
    }

    @discardableResult
    func install(_ agent: AgentKind) -> String? {
        guard integrations.first(where: { $0.id == agent })?.canManage == true else {
            return nil
        }
        lastError = nil
        if let error = performInstall(agent) {
            lastError = "\(agent.displayName): \(error)"
            return error
        }
        return nil
    }

    func installAll() {
        guard !isInstallingAll else { return }
        let agents = integrations
            .filter { $0.canManage && $0.detected && !$0.installed }
            .map(\.id)
        guard !agents.isEmpty else { return }

        isInstallingAll = true
        lastError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            var failures: [String] = []
            for agent in agents {
                operationStates[agent] = .installing
                await Task.yield()
                if let error = performInstall(agent, announceStart: false) {
                    failures.append("\(agent.displayName): \(error)")
                }
            }
            lastError = failures.isEmpty ? nil : failures.joined(separator: "\n")
            isInstallingAll = false
        }
    }

    /// Connects the selected agents that are both detected and backed by a
    /// managed connector. Runtime-only agents remain followable but never gain
    /// interaction capabilities through this path.
    @discardableResult
    func connectSelected(_ agents: Set<AgentKind>) -> [String] {
        let candidates = integrations.filter {
            agents.contains($0.id) && $0.detected && $0.canManage && !$0.installed
        }
        var failures: [String] = []
        for integration in candidates {
            if let error = performInstall(integration.id) {
                failures.append("\(integration.id.displayName): \(error)")
            }
        }
        lastError = failures.isEmpty ? nil : failures.joined(separator: "\n")
        return failures
    }

    @discardableResult
    private func performInstall(
        _ agent: AgentKind,
        announceStart: Bool = true
    ) -> String? {
        if announceStart {
            operationStates[agent] = .installing
        }
        do {
            switch agent {
            case .codex: try installCodex()
            case .antigravity: try installAntigravity()
            case .cursor: try installCursor()
            case .opencode: try installOpenCode()
            case .kimi: try installKimi()
            case .claude, .droid, .qoder, .qwen, .codebuddy:
                try installClaudeCompatible(agent)
            default:
                throw IntegrationError.unsupported(agent.displayName)
            }
            operationStates[agent] = .succeeded
            refresh()
            return nil
        } catch {
            let message = error.localizedDescription
            operationStates[agent] = .failed(message)
            return message
        }
    }

    func uninstall(_ agent: AgentKind) {
        do {
            guard let item = integrations.first(where: { $0.id == agent }),
                  item.canManage else { return }
            switch agent {
            case .antigravity:
                try uninstallAntigravity()
            case .cursor:
                try writeOrRemove(
                    ProviderHookConfiguration.removeCursorJSON(existingData: try? Data(contentsOf: item.configURL)),
                    at: item.configURL
                )
            case .opencode:
                try uninstallOpenCode(pluginURL: item.configURL)
            case .kimi:
                let existing = (try? String(contentsOf: item.configURL, encoding: .utf8)) ?? ""
                let cleaned = ProviderHookConfiguration.removeKimiTOML(existing: existing)
                try writeOrRemove(cleaned.data(using: .utf8), at: item.configURL)
            default:
                try writeOrRemove(
                    ProviderHookConfiguration.removeGroupedJSON(existingData: try? Data(contentsOf: item.configURL)),
                    at: item.configURL
                )
                if agent == .codex {
                    let config = home.appendingPathComponent(".codex/config.toml")
                    let existing = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
                    let cleaned = ProviderHookConfiguration.disableManagedCodexHooks(in: existing)
                    if cleaned != existing {
                        try backup(config)
                        try Data(cleaned.utf8).write(to: config, options: .atomic)
                    }
                }
            }
            lastError = nil
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func integration(_ descriptor: AgentIntegrationDescriptor) -> Integration {
        let agent = descriptor.agent
        let url = home.appendingPathComponent(descriptor.configurationPath)
        let detected = detect(descriptor)
        return Integration(
            id: agent,
            configURL: url,
            installed: descriptor.canManage ? isInstalled(agent, at: url) : false,
            detected: detected,
            note: descriptor.note,
            capabilities: ProviderEventAdapterRegistry.shared.adapter(for: agent).capabilities,
            canManage: descriptor.canManage
        )
    }

    private func isInstalled(_ agent: AgentKind, at url: URL) -> Bool {
        if agent == .antigravity {
            return antigravityPluginDirectories().contains {
                isManagedAntigravityPlugin(at: $0)
            }
        }
        if agent == .opencode {
            guard fileManager.fileExists(atPath: url.path) else { return false }
            let config = home.appendingPathComponent(".config/opencode/config.json")
            let contents = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
            return contents.contains("notch-agents")
        }
        let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let normalized = contents.lowercased().filter(\.isLetter)
        guard normalized.contains("notchagentsbridge")
            || (agent == .kimi
                && contents.contains(ProviderHookConfiguration.kimiMarker))
        else { return false }
        if agent == .codex {
            let config = home.appendingPathComponent(".codex/config.toml")
            let contents = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
            return ProviderHookConfiguration.codexHooksEnabled(in: contents)
        }
        return true
    }

    private func detect(
        _ descriptor: AgentIntegrationDescriptor
    ) -> Bool {
        if descriptor.evidencePaths.contains(where: {
            fileManager.fileExists(atPath: home.appendingPathComponent($0).path)
        }) {
            return true
        }
        let roots = [
            "/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".local/bin").path,
            home.appendingPathComponent(".npm/bin").path,
        ]
        if descriptor.executableNames.contains(where: { command in
            roots.contains { fileManager.isExecutableFile(atPath: "\($0)/\(command)") }
        }) {
            return true
        }
        let applicationRoots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
        ]
        return descriptor.applicationNames.contains { name in
            applicationRoots.contains {
                fileManager.fileExists(atPath: $0.appendingPathComponent(name).path)
            }
        }
    }

    nonisolated static func hasConfigurationEvidence(
        for agent: AgentKind,
        configExists: Bool,
        parentExists: Bool
    ) -> Bool {
        switch agent {
        case .t3code:
            return configExists
        case .warp:
            return false
        default:
            return configExists
        }
    }

    private var bridgeExecutablePath: String {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/notch-agents-bridge").path
        if fileManager.isExecutableFile(atPath: bundled) { return bundled }
        let adjacent = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("NotchAgentsBridge").path
        return adjacent
    }

    private func hookCommand(for agent: AgentKind) -> String {
        "\(shellQuote(bridgeExecutablePath)) --source \(agent.rawValue)"
    }

    private func installClaudeCompatible(_ agent: AgentKind) throws {
        guard let url = integrations.first(where: { $0.id == agent })?.configURL else { return }
        let toolMatcher = "*"
        let specs = [
            HookEventSpec("UserPromptSubmit"),
            HookEventSpec("SessionStart"),
            HookEventSpec("SessionEnd"),
            HookEventSpec("Stop"),
            HookEventSpec("StopFailure"),
            HookEventSpec("SubagentStart"),
            HookEventSpec("SubagentStop"),
            HookEventSpec("PermissionDenied", matcher: toolMatcher),
            HookEventSpec("PreCompact"),
            HookEventSpec("Notification", matcher: toolMatcher),
            HookEventSpec("PreToolUse", matcher: toolMatcher),
            HookEventSpec("PermissionRequest", matcher: toolMatcher, timeout: 86_400),
            HookEventSpec("PostToolUse", matcher: toolMatcher),
            HookEventSpec("PostToolUseFailure", matcher: toolMatcher),
        ]
        let data = try ProviderHookConfiguration.installGroupedJSON(
            existingData: try? Data(contentsOf: url),
            specs: specs,
            command: hookCommand(for: agent)
        )
        try write(data, at: url)
    }

    private func installCodex() throws {
        let hooksURL = home.appendingPathComponent(".codex/hooks.json")
        let specs = [
            HookEventSpec("SessionStart", matcher: "startup|resume", timeout: 45),
            HookEventSpec("UserPromptSubmit", timeout: 45),
            HookEventSpec("PermissionRequest", timeout: 3_600),
            HookEventSpec("Stop", timeout: 45),
        ]
        let hooks = try ProviderHookConfiguration.installGroupedJSON(
            existingData: try? Data(contentsOf: hooksURL),
            specs: specs,
            command: hookCommand(for: .codex)
        )
        try write(hooks, at: hooksURL)

        let configURL = home.appendingPathComponent(".codex/config.toml")
        let existing = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let enabled = ProviderHookConfiguration.enableCodexHooks(in: existing)
        if enabled != existing { try write(Data(enabled.utf8), at: configURL) }
    }

    private func installAntigravity() throws {
        let plugin = try ProviderHookConfiguration.antigravityPluginJSON()
        let hooks = try ProviderHookConfiguration.antigravityHooksJSON(
            command: hookCommand(for: .antigravity)
        )
        for directory in antigravityInstallDirectories() {
            if fileManager.fileExists(atPath: directory.path),
               !isManagedAntigravityPlugin(at: directory) {
                throw IntegrationError.unmanagedPlugin(directory.path)
            }
            try write(plugin, at: directory.appendingPathComponent("plugin.json"))
            try write(hooks, at: directory.appendingPathComponent("hooks.json"))
            let manifestURL = antigravityManifestURL(for: directory)
            let manifest = try ProviderHookConfiguration.registerAntigravityImport(
                existingData: try? Data(contentsOf: manifestURL)
            )
            try write(manifest, at: manifestURL)
        }
    }

    private func uninstallAntigravity() throws {
        for directory in antigravityPluginDirectories()
        where isManagedAntigravityPlugin(at: directory) {
            let manifestURL = antigravityManifestURL(for: directory)
            try writeOrRemove(
                ProviderHookConfiguration.unregisterAntigravityImport(
                    existingData: try? Data(contentsOf: manifestURL)
                ),
                at: manifestURL
            )
            try fileManager.removeItem(at: directory)
        }
    }

    private func antigravityPluginDirectories() -> [URL] {
        [
            home.appendingPathComponent(
                ".gemini/antigravity-cli/plugins/notch-agents",
                isDirectory: true
            ),
            home.appendingPathComponent(
                ".gemini/config/plugins/notch-agents",
                isDirectory: true
            ),
        ]
    }

    private func antigravityInstallDirectories() -> [URL] {
        var directories: [URL] = []
        let cliRoot = home.appendingPathComponent(".gemini/antigravity-cli")
        let cliExecutable = home.appendingPathComponent(".local/bin/agy").path
        if fileManager.fileExists(atPath: cliRoot.path)
            || fileManager.isExecutableFile(atPath: cliExecutable) {
            directories.append(antigravityPluginDirectories()[0])
        }
        let desktopRoot = home.appendingPathComponent(".gemini/antigravity")
        let desktopApp = URL(fileURLWithPath: "/Applications/Antigravity.app")
        if fileManager.fileExists(atPath: desktopRoot.path)
            || fileManager.fileExists(atPath: desktopApp.path) {
            directories.append(antigravityPluginDirectories()[1])
        }
        return directories
    }

    private func antigravityManifestURL(for pluginDirectory: URL) -> URL {
        pluginDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("import_manifest.json")
    }

    private func isManagedAntigravityPlugin(at directory: URL) -> Bool {
        ProviderHookConfiguration.isManagedAntigravityPlugin(
            pluginData: try? Data(contentsOf: directory.appendingPathComponent("plugin.json")),
            hooksData: try? Data(contentsOf: directory.appendingPathComponent("hooks.json"))
        )
    }

    private func installCursor() throws {
        let url = home.appendingPathComponent(".cursor/hooks.json")
        let data = try ProviderHookConfiguration.installCursorJSON(
            existingData: try? Data(contentsOf: url),
            command: hookCommand(for: .cursor)
        )
        try write(data, at: url)
    }

    private func installKimi() throws {
        let url = home.appendingPathComponent(".kimi/config.toml")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let output = ProviderHookConfiguration.installKimiTOML(
            existing: existing,
            command: hookCommand(for: .kimi)
        )
        try write(Data(output.utf8), at: url)
    }

    private func installOpenCode() throws {
        let pluginURL = home.appendingPathComponent(".config/opencode/plugins/notch-agents.js")
        let source = openCodePluginSource
        try write(Data(source.utf8), at: pluginURL)

        let configURL = home.appendingPathComponent(".config/opencode/config.json")
        let data = try ProviderHookConfiguration.registerOpenCodePlugin(
            existingData: try? Data(contentsOf: configURL),
            pluginURL: pluginURL
        )
        try write(data, at: configURL)
    }

    private func uninstallOpenCode(pluginURL: URL) throws {
        if fileManager.fileExists(atPath: pluginURL.path) {
            try backup(pluginURL)
            try fileManager.removeItem(at: pluginURL)
        }
        let configURL = home.appendingPathComponent(".config/opencode/config.json")
        try writeOrRemove(
            ProviderHookConfiguration.unregisterOpenCodePlugin(existingData: try? Data(contentsOf: configURL)),
            at: configURL
        )
    }

    private var openCodePluginSource: String {
        """
        // Adapted from Open Island's GPL-3.0 OpenCode lifecycle bridge.
        // Notch Agents uses its loopback HTTP reducer instead of a Unix socket.
        const endpoint = "http://127.0.0.1:18989/event";

        function normalizedQuestion(question, index) {
          const prompt = question?.question || question?.title || question?.prompt;
          if (!prompt) return null;
          return {
            id: question.id || `question-${index + 1}`,
            header: question.header || question.label,
            prompt: String(prompt),
            options: (question.options || []).map((option) => {
              if (typeof option === "string") return option;
              return {
                id: option.id || option.value || option.label,
                label: option.label || option.text || option.value || option.name,
                value: option.value || option.label || option.text
              };
            }),
            allows_multiple: Boolean(question.multiSelect || question.multi_select),
            allows_other: Boolean(question.allowsFreeform || question.allows_freeform)
          };
        }

        async function send(payload) {
          const response = await fetch(endpoint, {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify(payload)
          });
          return response.ok ? response.json() : null;
        }

        export default async ({ client, serverUrl, project }) => {
          const messageRoles = new Map();
          const sessionCwds = new Map();
          const sessionState = new Map();
          const internalFetch = client?._client?.getConfig?.()?.fetch;
          const serverBase = serverUrl || new URL("http://localhost:4096");
          const authorization = process.env.OPENCODE_SERVER_USERNAME
            ? `Basic ${btoa(`${process.env.OPENCODE_SERVER_USERNAME}:${process.env.OPENCODE_SERVER_PASSWORD || ""}`)}`
            : null;

          function state(sessionID) {
            if (!sessionState.has(sessionID)) {
              sessionState.set(sessionID, { lastAssistantText: "" });
            }
            return sessionState.get(sessionID);
          }

          function payload(eventName, sessionID, extra = {}) {
            return {
              source: "opencode",
              event_name: eventName,
              session_id: `opencode-${sessionID}`,
              cwd: sessionCwds.get(sessionID) || project?.worktree || project?.path,
              project: project?.name,
              ...extra
            };
          }

          function replyURL(path, sessionID) {
            const url = new URL(path, serverBase);
            const directory = sessionCwds.get(sessionID) || project?.worktree || project?.path;
            if (directory) url.searchParams.set("directory", directory);
            return url;
          }

          function replyHeaders() {
            return {
              "content-type": "application/json",
              ...(authorization ? { authorization } : {})
            };
          }

          async function replyToPermission(requestID, sessionID, response) {
            const decision = response?.decision;
            if (!decision || !internalFetch) return;
            const instruction = response?.output?.instruction?.trim();
            const body = {
              reply: decision === "allow" ? "once" : "reject"
            };
            if (decision !== "allow" && instruction) {
              body.message = instruction;
            }
            await internalFetch(new Request(
              replyURL(`/permission/${requestID}/reply`, sessionID),
              {
                method: "POST",
                headers: replyHeaders(),
                body: JSON.stringify(body)
              }
            ));
          }

          async function replyToQuestions(requestID, sessionID, questions, response) {
            if (!response?.answers || !internalFetch) return;
            const answers = questions.map((question) => {
              const answer = response.answers[question.id];
              const selected = Array.isArray(answer?.selected) ? answer.selected : [];
              return selected.length > 0 ? selected : [answer?.text || ""];
            });
            await internalFetch(new Request(
              replyURL(`/question/${requestID}/reply`, sessionID),
              {
                method: "POST",
                headers: replyHeaders(),
                body: JSON.stringify({ answers })
              }
            ));
          }

          return {
            event: async ({ event }) => {
              try {
                const type = event?.type;
                const properties = event?.properties || {};
                const info = properties.info || {};
                const part = properties.part || {};

                if (type === "session.created" && info.id) {
                  sessionCwds.set(info.id, info.directory || "");
                  await send(payload("SessionStart", info.id, {
                    conversation_title: info.title
                  }));
                  return;
                }
                if (type === "session.updated" && info.id) {
                  if (info.directory) sessionCwds.set(info.id, info.directory);
                  if (info.time?.archived) {
                    await send(payload("SessionEnd", info.id));
                    sessionCwds.delete(info.id);
                    sessionState.delete(info.id);
                  }
                  return;
                }
                if (type === "session.deleted" && info.id) {
                  await send(payload("SessionEnd", info.id));
                  sessionCwds.delete(info.id);
                  sessionState.delete(info.id);
                  return;
                }
                if (type === "session.status" && properties.sessionID) {
                  if (properties.status?.type === "idle") {
                    await send(payload("Stop", properties.sessionID, {
                      last_assistant_message: state(properties.sessionID).lastAssistantText
                    }));
                  }
                  return;
                }
                if (type === "message.updated" && info.id && info.sessionID) {
                  messageRoles.set(info.id, {
                    role: info.role,
                    sessionID: info.sessionID
                  });
                  if (messageRoles.size > 200) {
                    messageRoles.delete(messageRoles.keys().next().value);
                  }
                  return;
                }
                if (type === "message.part.updated" && part.type === "text") {
                  const metadata = messageRoles.get(part.messageID);
                  if (!metadata || !part.text) return;
                  if (metadata.role === "user") {
                    await send(payload("UserPromptSubmit", metadata.sessionID, {
                      prompt: part.text
                    }));
                  } else if (metadata.role === "assistant") {
                    state(metadata.sessionID).lastAssistantText = part.text;
                  }
                  return;
                }
                if (type === "message.part.updated" && part.type === "tool" && part.sessionID) {
                  const toolState = part.state?.status;
                  const eventName = toolState === "completed" || toolState === "error"
                    ? (toolState === "error" ? "PostToolUseFailure" : "PostToolUse")
                    : "PreToolUse";
                  await send(payload(eventName, part.sessionID, {
                    tool_name: part.tool,
                    tool_input: part.state?.input,
                    error: toolState === "error" ? "Tool failed" : undefined
                  }));
                  return;
                }
                if (type === "permission.asked" && properties.id && properties.sessionID) {
                  const response = await send(payload("PermissionRequest", properties.sessionID, {
                    blocking: true,
                    request_id: properties.id,
                    tool_name: properties.permission,
                    message: (properties.patterns || []).join(" · ")
                      || "OpenCode needs permission"
                  }));
                  await replyToPermission(properties.id, properties.sessionID, response);
                  return;
                }
                if (type === "question.asked" && properties.id && properties.sessionID) {
                  const questions = (properties.questions || [])
                    .map(normalizedQuestion)
                    .filter(Boolean);
                  const response = await send(payload("QuestionAsked", properties.sessionID, {
                    blocking: true,
                    request_id: properties.id,
                    questions
                  }));
                  await replyToQuestions(properties.id, properties.sessionID, questions, response);
                  return;
                }
                if ((type === "permission.replied"
                  || type === "question.replied"
                  || type === "question.rejected") && properties.sessionID) {
                  await send(payload("PostToolUse", properties.sessionID));
                }
              } catch {
                // Fail open: OpenCode must not depend on the island.
              }
            }
          };
        };
        """
    }

    private func write(_ data: Data, at url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try backup(url)
        try data.write(to: url, options: .atomic)
    }

    private func writeOrRemove(_ data: Data?, at url: URL) throws {
        guard let data, !data.isEmpty else {
            if fileManager.fileExists(atPath: url.path) {
                try backup(url)
                try fileManager.removeItem(at: url)
            }
            return
        }
        try write(data, at: url)
    }

    private func backup(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let backup = url.appendingPathExtension("notch-agents.backup")
        if fileManager.fileExists(atPath: backup.path) { try fileManager.removeItem(at: backup) }
        try fileManager.copyItem(at: url, to: backup)
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

private enum IntegrationError: LocalizedError {
    case unsupported(String)
    case unmanagedPlugin(String)

    var errorDescription: String? {
        switch self {
        case let .unsupported(name): "\(name) does not expose a supported hook format."
        case let .unmanagedPlugin(path):
            "Refusing to overwrite an unmanaged Antigravity plugin at \(path)."
        }
    }
}
