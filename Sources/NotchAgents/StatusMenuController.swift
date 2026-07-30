import AppKit
import Combine

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let store: SessionStore
    private let openSettings: () -> Void
    private let checkForUpdates: () -> Void
    private let quitApplication: () -> Void
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var cancellables: Set<AnyCancellable> = []

    init(
        store: SessionStore,
        openSettings: @escaping () -> Void,
        checkForUpdates: @escaping () -> Void,
        quitApplication: @escaping () -> Void
    ) {
        self.store = store
        self.openSettings = openSettings
        self.checkForUpdates = checkForUpdates
        self.quitApplication = quitApplication
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        statusItem.button?.image = ThinkingOrbMenuBarIcon.makeImage(pointSize: 17)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.menu = menu
        menu.delegate = self

        Publishers.CombineLatest3(
            store.$sessions,
            store.$serverIsReady,
            store.$processMonitorIsReady
        )
        .sink { [weak self] _, _, _ in self?.updateStatusItemDescription() }
        .store(in: &cancellables)
        updateStatusItemDescription()
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let summary = NSMenuItem(title: summaryTitle, action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)

        let toggle = item(
            store.isExpanded ? "Hide Notch" : "Show Notch",
            action: #selector(toggleNotch)
        )
        toggle.keyEquivalent = "n"
        toggle.keyEquivalentModifierMask = [.control, .option]
        toggle.isEnabled = !store.isExpanded || !store.isPinned
        menu.addItem(toggle)

        let sessions = Array(store.visibleSessions.prefix(5))
        if sessions.isEmpty {
            let empty = NSMenuItem(
                title: store.processMonitorIsReady ? "No current sessions" : "Finding agents…",
                action: nil,
                keyEquivalent: ""
            )
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            menu.addItem(.separator())
            for session in sessions {
                let sessionItem = item(
                    conciseTitle(for: session),
                    action: #selector(openSession(_:))
                )
                sessionItem.representedObject = session.id
                sessionItem.image = menuImage(for: session.agent)
                menu.addItem(sessionItem)
            }
            if store.visibleSessions.count > sessions.count {
                let remainder = store.visibleSessions.count - sessions.count
                let more = NSMenuItem(
                    title: "\(remainder) more session\(remainder == 1 ? "" : "s")",
                    action: nil,
                    keyEquivalent: ""
                )
                more.isEnabled = false
                menu.addItem(more)
            }
            menu.addItem(
                item("Show All Sessions", action: #selector(showAllSessions))
            )
        }

        menu.addItem(.separator())
        let mute = item(
            UserDefaults.standard.bool(forKey: "notchAgents.muted")
                ? "Unmute Sounds"
                : "Mute Sounds",
            action: #selector(toggleMute)
        )
        mute.state = UserDefaults.standard.bool(forKey: "notchAgents.muted") ? .on : .off
        menu.addItem(mute)
        menu.addItem(item("Settings…", action: #selector(openSettingsAction), key: ","))
        menu.addItem(item("Check for Updates…", action: #selector(checkForUpdatesAction)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Notch Agents", action: #selector(quitAction), key: "q"))
    }

    private var summaryTitle: String {
        if !store.serverIsReady {
            return "Local bridge offline"
        }
        let sessionCount = store.visibleSessions.count
        let attentionCount = store.attentionCount
        if attentionCount > 0 {
            return "\(sessionCount) sessions · \(attentionCount) waiting"
        }
        return "\(sessionCount) session\(sessionCount == 1 ? "" : "s")"
    }

    private func conciseTitle(for session: AgentSession) -> String {
        let project = session.projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = project.isEmpty || ["/", "."].contains(project)
            ? session.agent.displayName
            : project
        let state = session.activity.phase.accessibilityLabel
        let suffix = " · \(state)"
        let maximumSubjectLength = max(8, 30 - suffix.count)
        return "\(subject.truncated(to: maximumSubjectLength))\(suffix)"
    }

    private func menuImage(for agent: AgentKind) -> NSImage? {
        guard let source = BrandIconResolver.image(for: agent),
              let image = source.copy() as? NSImage else { return nil }
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    private func updateStatusItemDescription() {
        let count = store.visibleSessions.count
        let attention = store.attentionCount
        let description = if attention > 0 {
            "Notch Agents, \(attention) request\(attention == 1 ? "" : "s") waiting"
        } else {
            "Notch Agents, \(count) session\(count == 1 ? "" : "s")"
        }
        statusItem.button?.toolTip = description
        statusItem.button?.setAccessibilityLabel(description)
    }

    private func item(
        _ title: String,
        action: Selector,
        key: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func toggleNotch() {
        store.toggleExpanded()
    }

    @objc private func openSession(_ sender: NSMenuItem) {
        guard let sessionID = sender.representedObject as? String,
              let session = store.visibleSessions.first(where: { $0.id == sessionID }) else {
            return
        }
        if session.interaction != nil {
            store.focusSession(id: sessionID)
        } else {
            store.jump(to: session)
        }
    }

    @objc private func showAllSessions() {
        store.showAllSessions()
    }

    @objc private func toggleMute() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: "notchAgents.muted"), forKey: "notchAgents.muted")
    }

    @objc private func openSettingsAction() {
        openSettings()
    }

    @objc private func checkForUpdatesAction() {
        checkForUpdates()
    }

    @objc private func quitAction() {
        quitApplication()
    }
}

private extension String {
    func truncated(to maximumLength: Int) -> String {
        guard count > maximumLength else { return self }
        return String(prefix(max(1, maximumLength - 1))) + "…"
    }
}
