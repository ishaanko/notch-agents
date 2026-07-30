import Carbon
import Foundation

enum GlobalShortcutPreferences {
    static let enabledKey = "notchAgents.globalShortcutEnabled"
    static let displayName = "Control–Option–N"

    static func registerDefaults(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [enabledKey: true])
    }
}

@MainActor
final class GlobalShortcutController {
    private static let hotKeySignature: OSType = 0x4E_41_47_54 // NAGT
    private static let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: 1)
    private static let eventHandler: EventHandlerUPP = { _, _, userData in
        guard let userData else { return OSStatus(eventNotHandledErr) }
        let controller = Unmanaged<GlobalShortcutController>
            .fromOpaque(userData)
            .takeUnretainedValue()
        Task { @MainActor in controller.performAction() }
        return noErr
    }

    private let defaults: UserDefaults
    private let action: () -> Void
    private var hotKeyReference: EventHotKeyRef?
    private var eventHandlerReference: EventHandlerRef?
    private var preferencesObserver: NSObjectProtocol?

    init(
        defaults: UserDefaults = .standard,
        action: @escaping () -> Void
    ) {
        self.defaults = defaults
        self.action = action
        installEventHandler()
        updateRegistration()
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateRegistration() }
        }
    }

    deinit {
        if let hotKeyReference {
            UnregisterEventHotKey(hotKeyReference)
        }
        if let eventHandlerReference {
            RemoveEventHandler(eventHandlerReference)
        }
        if let preferencesObserver {
            NotificationCenter.default.removeObserver(preferencesObserver)
        }
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerReference
        )
    }

    private func updateRegistration() {
        let shouldRegister = defaults.bool(forKey: GlobalShortcutPreferences.enabledKey)
        if shouldRegister, hotKeyReference == nil {
            RegisterEventHotKey(
                UInt32(kVK_ANSI_N),
                UInt32(controlKey | optionKey),
                Self.hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyReference
            )
        } else if !shouldRegister, let hotKeyReference {
            UnregisterEventHotKey(hotKeyReference)
            self.hotKeyReference = nil
        }
    }

    private func performAction() {
        guard defaults.bool(forKey: GlobalShortcutPreferences.enabledKey) else { return }
        action()
    }
}
