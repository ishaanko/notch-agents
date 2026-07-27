import Foundation

struct HookEventSpec: Equatable, Sendable {
    var name: String
    var matcher: String?
    var timeout: Int?

    init(_ name: String, matcher: String? = nil, timeout: Int? = nil) {
        self.name = name
        self.matcher = matcher
        self.timeout = timeout
    }
}

enum ProviderHookConfiguration {
    static let marker = "notch-agents-bridge"
    static let kimiMarker = "# notch-agents: managed hook"
    static let codexFeatureMarker = "# notch-agents: enabled hooks"

    static func installGroupedJSON(
        existingData: Data?,
        specs: [HookEventSpec],
        command: String
    ) throws -> Data {
        var root = try jsonRoot(existingData)
        let existingHooks = root["hooks"] as? [String: Any] ?? [:]
        var hooks: [String: Any] = [:]

        for (event, rawValue) in existingHooks {
            let groups = rawValue as? [Any] ?? []
            let cleaned = cleanGroupedHooks(groups)
            if !cleaned.isEmpty { hooks[event] = cleaned }
        }

        for spec in specs {
            let current = cleanGroupedHooks(hooks[spec.name] as? [Any] ?? [])
            var hook: [String: Any] = [
                "type": "command",
                "command": command,
                "name": "Notch Agents",
            ]
            if let timeout = spec.timeout { hook["timeout"] = timeout }
            var group: [String: Any] = ["hooks": [hook]]
            if let matcher = spec.matcher { group["matcher"] = matcher }
            hooks[spec.name] = current + [group]
        }

        root["hooks"] = hooks
        return try serialize(root)
    }

    static func removeGroupedJSON(existingData: Data?) throws -> Data? {
        guard existingData != nil else { return nil }
        var root = try jsonRoot(existingData)
        let existingHooks = root["hooks"] as? [String: Any] ?? [:]
        var hooks: [String: Any] = [:]
        for (event, rawValue) in existingHooks {
            let cleaned = cleanGroupedHooks(rawValue as? [Any] ?? [])
            if !cleaned.isEmpty { hooks[event] = cleaned }
        }
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        return root.isEmpty ? nil : try serialize(root)
    }

    static func installCursorJSON(existingData: Data?, command: String) throws -> Data {
        let events = [
            "beforeSubmitPrompt", "beforeShellExecution", "beforeMCPExecution",
            "beforeReadFile", "afterFileEdit", "stop",
        ]
        var root = try jsonRoot(existingData)
        root["version"] = 1
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in events {
            let existing = hooks[event] as? [[String: Any]] ?? []
            hooks[event] = existing.filter { !isManagedCommand($0["command"] as? String) }
                + [["command": command]]
        }
        root["hooks"] = hooks
        return try serialize(root)
    }

    static func removeCursorJSON(existingData: Data?) throws -> Data? {
        guard existingData != nil else { return nil }
        var root = try jsonRoot(existingData)
        let existingHooks = root["hooks"] as? [String: Any] ?? [:]
        var hooks: [String: Any] = [:]
        for (event, rawValue) in existingHooks {
            if let entries = rawValue as? [[String: Any]] {
                let cleaned = entries.filter { !isManagedCommand($0["command"] as? String) }
                if !cleaned.isEmpty { hooks[event] = cleaned }
            } else {
                hooks[event] = rawValue
            }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        if root.count == 1, root["version"] != nil { root.removeAll() }
        return root.isEmpty ? nil : try serialize(root)
    }

    static func enableCodexHooks(in existing: String) -> String {
        var lines = existing.components(separatedBy: "\n")
        if let range = sectionRange(named: "features", in: lines) {
            if let hookLine = keyLine("hooks", in: range, lines: lines) {
                let enabled = valueOnAssignmentLine(lines[hookLine]) == "true"
                if enabled { return existing }
                lines.insert(codexFeatureMarker, at: hookLine)
                lines[hookLine + 1] = "hooks = true"
                return lines.joined(separator: "\n")
            }
            lines.insert(contentsOf: [codexFeatureMarker, "hooks = true"], at: range.upperBound)
            return lines.joined(separator: "\n")
        }
        if !lines.isEmpty, lines.last?.isEmpty == false { lines.append("") }
        lines.append(contentsOf: ["[features]", codexFeatureMarker, "hooks = true"])
        return lines.joined(separator: "\n")
    }

    static func disableManagedCodexHooks(in existing: String) -> String {
        var lines = existing.components(separatedBy: "\n")
        guard let markerIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == codexFeatureMarker
        }) else { return existing }
        lines.remove(at: markerIndex)
        if markerIndex < lines.count,
           assignmentKey(lines[markerIndex]) == "hooks" {
            lines.remove(at: markerIndex)
        }
        if let range = sectionRange(named: "features", in: lines) {
            let meaningful = lines[(range.lowerBound + 1)..<range.upperBound]
                .contains { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    return !trimmed.isEmpty && !trimmed.hasPrefix("#")
                }
            if !meaningful {
                lines.removeSubrange(range)
            }
        }
        return lines.joined(separator: "\n")
    }

    static func codexHooksEnabled(in existing: String) -> Bool {
        let lines = existing.components(separatedBy: "\n")
        guard let range = sectionRange(named: "features", in: lines),
              let line = keyLine("hooks", in: range, lines: lines) else { return false }
        return valueOnAssignmentLine(lines[line]) == "true"
    }

    static func installKimiTOML(existing: String, command: String) -> String {
        var output = removeKimiTOML(existing: existing)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let specs = [
            HookEventSpec("SessionStart", matcher: "startup|resume"),
            HookEventSpec("UserPromptSubmit"),
            HookEventSpec("Stop"),
            HookEventSpec("Notification"),
            HookEventSpec("PreToolUse"),
            HookEventSpec("PostToolUse"),
        ]
        for spec in specs {
            if !output.isEmpty { output += "\n\n" }
            output += "\(kimiMarker)\n[[hooks]]\nevent = \"\(spec.name)\"\n"
            if let matcher = spec.matcher { output += "matcher = \"\(matcher)\"\n" }
            output += "command = \(tomlString(command))\ntimeout = 45"
        }
        return output + "\n"
    }

    static func removeKimiTOML(existing: String) -> String {
        let lines = existing.components(separatedBy: "\n")
        var result: [String] = []
        var index = 0
        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces) == kimiMarker {
                index += 1
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    index += 1
                }
                if index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) == "[[hooks]]" {
                    index += 1
                    while index < lines.count {
                        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                        if trimmed.hasPrefix("[") || trimmed == kimiMarker { break }
                        index += 1
                    }
                    continue
                }
            }
            result.append(lines[index])
            index += 1
        }
        let cleaned = result.joined(separator: "\n")
        let legacyPattern = #"(?s)\n?# --- notch-agents hooks START \(managed\) ---.*?# --- notch-agents hooks END ---\n?"#
        return cleaned.replacingOccurrences(of: legacyPattern, with: "", options: .regularExpression)
    }

    static func registerOpenCodePlugin(existingData: Data?, pluginURL: URL) throws -> Data {
        var root = try jsonRoot(existingData)
        let registration = pluginURL.absoluteURL.absoluteString
        var plugins = root["plugin"] as? [String] ?? []
        plugins.removeAll { $0.contains("notch-agents") }
        plugins.append(registration)
        root["plugin"] = plugins
        return try serialize(root)
    }

    static func unregisterOpenCodePlugin(existingData: Data?) throws -> Data? {
        guard existingData != nil else { return nil }
        var root = try jsonRoot(existingData)
        var plugins = root["plugin"] as? [String] ?? []
        plugins.removeAll { $0.contains("notch-agents") }
        if plugins.isEmpty { root.removeValue(forKey: "plugin") } else { root["plugin"] = plugins }
        return root.isEmpty ? nil : try serialize(root)
    }

    static func antigravityPluginJSON() throws -> Data {
        try serialize([
            "description": "Forwards Antigravity lifecycle hooks to Notch Agents.",
            "displayName": "Notch Agents",
            "managedBy": "notch-agents",
            "name": "notch-agents",
            "version": "0.1.1",
        ])
    }

    static func antigravityHooksJSON(command: String) throws -> Data {
        func handler(_ event: String) -> [String: Any] {
            [
                "type": "command",
                "command": "\(command) --event \(event)",
                "timeout": 5,
            ]
        }
        let plugin: [String: Any] = [
            "enabled": true,
            "PreInvocation": [handler("PreInvocation")],
            "PostInvocation": [handler("PostInvocation")],
            "PostToolUse": [[
                "matcher": "*",
                "hooks": [handler("PostToolUse")],
            ]],
            "Stop": [handler("Stop")],
        ]
        return try serialize(["notch-agents": plugin])
    }

    static func registerAntigravityImport(
        existingData: Data?,
        importedAt: Date = Date()
    ) throws -> Data {
        var root = try jsonRoot(existingData)
        var imports = root["imports"] as? [[String: Any]] ?? []
        imports.removeAll { ($0["name"] as? String) == "notch-agents" }
        imports.append([
            "components": ["installed"],
            "importedAt": ISO8601DateFormatter().string(from: importedAt),
            "name": "notch-agents",
            "source": "local-install",
        ])
        root["imports"] = imports
        return try serialize(root)
    }

    static func unregisterAntigravityImport(existingData: Data?) throws -> Data? {
        guard existingData != nil else { return nil }
        var root = try jsonRoot(existingData)
        var imports = root["imports"] as? [[String: Any]] ?? []
        imports.removeAll { ($0["name"] as? String) == "notch-agents" }
        if imports.isEmpty {
            root.removeValue(forKey: "imports")
        } else {
            root["imports"] = imports
        }
        return root.isEmpty ? nil : try serialize(root)
    }

    static func isManagedAntigravityPlugin(
        pluginData: Data?,
        hooksData: Data?
    ) -> Bool {
        guard let pluginData,
              let plugin = try? jsonRoot(pluginData),
              (plugin["managedBy"] as? String) == "notch-agents",
              let hooksData,
              let hooks = try? jsonRoot(hooksData),
              hooks["notch-agents"] != nil else { return false }
        return true
    }

    private static func cleanGroupedHooks(_ groups: [Any]) -> [[String: Any]] {
        groups.compactMap { rawGroup in
            guard var group = rawGroup as? [String: Any] else { return nil }
            let hooks = group["hooks"] as? [[String: Any]] ?? []
            let cleaned = hooks.filter { !isManagedCommand($0["command"] as? String) }
            guard !cleaned.isEmpty else { return nil }
            group["hooks"] = cleaned
            return group
        }
    }

    private static func isManagedCommand(_ command: String?) -> Bool {
        guard let command else { return false }
        let normalized = command.lowercased().filter(\.isLetter)
        return normalized.contains("notchagentsbridge")
    }

    private static func jsonRoot(_ data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        let value = try JSONSerialization.jsonObject(with: data)
        guard let root = value as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return root
    }

    private static func serialize(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    private static func sectionRange(named name: String, in lines: [String]) -> Range<Int>? {
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "[\(name)]"
        }) else { return nil }
        let end = lines[(start + 1)...].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("[")
        }) ?? lines.endIndex
        return start..<end
    }

    private static func keyLine(_ key: String, in range: Range<Int>, lines: [String]) -> Int? {
        lines.indices.first { range.contains($0) && assignmentKey(lines[$0]) == key }
    }

    private static func assignmentKey(_ line: String) -> String? {
        let syntax = line.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
        return syntax.split(separator: "=", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespaces)
    }

    private static func valueOnAssignmentLine(_ line: String) -> String? {
        let syntax = line.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
        let parts = syntax.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return parts[1].trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func tomlString(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
