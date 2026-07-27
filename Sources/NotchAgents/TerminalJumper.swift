import AppKit
import Foundation

enum TerminalJumper {
    static func jump(to session: AgentSession) {
        if session.agent == .codex,
           let threadID = session.threadID,
           !threadID.isEmpty,
           let encoded = threadID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = URL(string: "codex://threads/\(encoded)") {
            NSWorkspace.shared.open(url)
            return
        }

        if let bundleID = session.terminalBundleID,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate(options: [.activateAllWindows])
            focusKnownTerminal(bundleID: bundleID, sessionID: session.terminalSessionID)
            return
        }

        if session.agent == .antigravity, launchAntigravityConversation(session) {
            return
        }

        let candidates = [
            "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
            "com.apple.Terminal", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
            "com.exafunction.windsurf", "com.github.wez.wezterm", "com.openai.codex",
            "com.t3tools.t3code", "com.conductor.app"
        ]
        for bundleID in candidates {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                app.activate(options: [.activateAllWindows])
                return
            }
        }

        if let cwd = session.cwd {
            let url = URL(fileURLWithPath: cwd)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private static func launchAntigravityConversation(_ session: AgentSession) -> Bool {
        let conversationID = session.threadID ?? session.id
        guard !conversationID.isEmpty,
              !conversationID.hasPrefix("process:"),
              let executable = [
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".local/bin/agy").path,
                "/opt/homebrew/bin/agy",
                "/usr/local/bin/agy",
              ].first(where: FileManager.default.isExecutableFile(atPath:)) else {
            return false
        }
        let cwd = session.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        let command = "cd \(shellQuote(cwd)) && \(shellQuote(executable)) --conversation \(shellQuote(conversationID))"
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func focusKnownTerminal(bundleID: String, sessionID: String?) {
        guard let sessionID, !sessionID.isEmpty else { return }
        let escaped = sessionID.replacingOccurrences(of: "\"", with: "\\\"")
        let source: String?
        switch bundleID {
        case "com.googlecode.iterm2":
            source = """
            tell application "iTerm2"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if id of s is "\(escaped)" then
                                select t
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """
        case "com.apple.Terminal":
            source = "tell application \"Terminal\" to activate"
        default:
            source = nil
        }
        if let source { NSAppleScript(source: source)?.executeAndReturnError(nil) }
    }
}
