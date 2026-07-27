import AppKit
import Foundation

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private let integrations = IntegrationManager()
    private let usage = UsageMonitor()
    private let updates = UpdateManager()
    private var eventServer: LocalEventServer?
    private var codexWatcher: CodexSessionWatcher?
    private var processMonitor: AgentProcessMonitor?
    private var notchController: NotchWindowController?
    private var settingsController: SettingsWindowController?
    private var onboardingController: FirstLaunchOnboardingController?
    private var statusItem: NSStatusItem?

    static func main() {
        AppMotionPolicy.normalizePreferences()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if OnboardingPreferences.isCompleted() {
            AgentFollowPreferences.initializeIfNeeded(
                detectedAgents: Set(integrations.integrations.filter(\.detected).map(\.id))
            )
        }

        settingsController = SettingsWindowController(
            store: store,
            integrations: integrations,
            usage: usage,
            updates: updates
        )
        notchController = NotchWindowController(
            store: store,
            usage: usage,
            openSettings: { [weak self] in self?.settingsController?.present() },
            quitApplication: { NSApp.terminate(nil) }
        )
        notchController?.show()
        configureStatusItem()
        presentOnboardingIfNeeded()

        let server = LocalEventServer { [weak self] payload, reply in
            Task { @MainActor in
                self?.usage.ingest(payload)
                self?.store.ingest(payload, reply: reply)
            }
        }
        server.onStateChange = { [weak self] ready in
            Task { @MainActor in self?.store.setServerReady(ready) }
        }
        eventServer = server
        server.start()

        let watcher = CodexSessionWatcher { [weak self] sessions in
            self?.store.mergeDiscoveredCodexSessions(sessions)
        }
        codexWatcher = watcher
        watcher.start()

        let monitor = AgentProcessMonitor { [weak self] snapshots in
            Task { @MainActor in
                self?.store.reconcileProcesses(snapshots)
            }
        }
        processMonitor = monitor
        monitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        eventServer?.stop()
        codexWatcher?.stop()
        processMonitor?.stop()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = ThinkingOrbMenuBarIcon.makeImage(pointSize: 17)
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "Notch Agents"
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Toggle Notch", action: #selector(toggleNotch), keyEquivalent: "n")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Notch Agents", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    private func presentOnboardingIfNeeded() {
        guard FirstLaunchOnboardingController.shouldPresent else { return }
        let controller = FirstLaunchOnboardingController(integrations: integrations) { [weak self] in
            self?.onboardingController = nil
        }
        onboardingController = controller
        controller.present()
    }

    @objc private func toggleNotch() { store.isExpanded.toggle() }
    @objc private func openSettings() { settingsController?.present() }
    @objc private func checkForUpdates() {
        Task { await updates.check() }
        settingsController?.present()
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
