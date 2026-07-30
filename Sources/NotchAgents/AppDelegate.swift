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
    private var statusMenuController: StatusMenuController?
    private var globalShortcutController: GlobalShortcutController?

    static func main() {
        AppMotionPolicy.normalizePreferences()
        GlobalShortcutPreferences.registerDefaults()
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
        statusMenuController = StatusMenuController(
            store: store,
            openSettings: { [weak self] in self?.settingsController?.present() },
            checkForUpdates: { [weak self] in
                Task { await self?.updates.check() }
                self?.settingsController?.present()
            },
            quitApplication: { NSApp.terminate(nil) }
        )
        globalShortcutController = GlobalShortcutController { [weak store] in
            store?.toggleExpanded()
        }
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

    private func presentOnboardingIfNeeded() {
        guard FirstLaunchOnboardingController.shouldPresent else { return }
        let controller = FirstLaunchOnboardingController(integrations: integrations) { [weak self] in
            self?.onboardingController = nil
        }
        onboardingController = controller
        controller.present()
    }

}
