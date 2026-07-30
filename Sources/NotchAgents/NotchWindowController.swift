import AppKit
import Combine
import QuartzCore
import SwiftUI

struct NotchDisplayDescriptor: Equatable, Sendable {
    var displayID: UInt32
    var frame: CGRect
    var backingScale: CGFloat
    var hasHardwareNotch: Bool
    var isMain: Bool
}

enum NotchDisplayResolver {
    static func resolve(_ displays: [NotchDisplayDescriptor]) -> NotchDisplayDescriptor? {
        displays.first(where: \.hasHardwareNotch)
            ?? displays.first(where: \.isMain)
            ?? displays.first
    }

    static func pixelAlignedFrame(
        size requestedSize: CGSize,
        on display: NotchDisplayDescriptor
    ) -> CGRect {
        let scale = max(1, display.backingScale)
        func align(_ value: CGFloat) -> CGFloat {
            (value * scale).rounded() / scale
        }
        let size = CGSize(
            width: align(requestedSize.width),
            height: align(requestedSize.height)
        )
        return CGRect(
            x: align(display.frame.midX - size.width / 2),
            y: align(display.frame.maxY - size.height),
            width: size.width,
            height: size.height
        )
    }

    static func connectedDisplay(
        id displayID: UInt32,
        in displays: [NotchDisplayDescriptor]
    ) -> NotchDisplayDescriptor? {
        displays.first { $0.displayID == displayID }
    }

    static func fixedPanelFrame(on display: NotchDisplayDescriptor) -> CGRect {
        pixelAlignedFrame(
            size: CGSize(
                width: NotchTheme.expandedWidth,
                height: NotchTheme.maximumExpandedHeight
            ),
            on: display
        )
    }
}

struct NotchSilhouette: Equatable, Sendable {
    var rect: CGRect
    var bottomCornerRadius: CGFloat

    func contains(_ point: CGPoint) -> Bool {
        guard rect.contains(point) else { return false }
        let radius = min(
            max(0, bottomCornerRadius),
            min(rect.width / 2, rect.height)
        )
        guard radius > 0, point.y < rect.minY + radius else {
            return true
        }
        if point.x >= rect.minX + radius, point.x <= rect.maxX - radius {
            return true
        }
        let centerX = point.x < rect.midX ? rect.minX + radius : rect.maxX - radius
        let centerY = rect.minY + radius
        let dx = point.x - centerX
        let dy = point.y - centerY
        return dx * dx + dy * dy <= radius * radius
    }
}

struct NotchHoverTransitionState: Equatable, Sendable {
    private(set) var isHovered = false

    mutating func update(_ hovered: Bool) -> Bool? {
        guard hovered != isHovered else { return nil }
        isHovered = hovered
        return hovered
    }
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class NotchSurfaceContainerView: NSView {
    private let surfaceLayer = CALayer()
    private(set) var surfaceGeometry = NotchSurfaceMotionController.Geometry.compact
    var onHoverChange: ((Bool) -> Void)?
    private var hoverState = NotchHoverTransitionState()
    private var pointerTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false
        surfaceLayer.backgroundColor = NotchTheme.notchCGColor
        surfaceLayer.isOpaque = true
        surfaceLayer.opacity = 1
        surfaceLayer.cornerCurve = .continuous
        surfaceLayer.anchorPoint = CGPoint(x: 0.5, y: 1)
        surfaceLayer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        surfaceLayer.masksToBounds = true
        layer?.addSublayer(surfaceLayer)
        apply(geometry: .compact)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        alignSurfaceToCurrentBounds()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        alignSurfaceToCurrentBounds()
    }

    override func layout() {
        super.layout()
        alignSurfaceToCurrentBounds()
    }

    private func alignSurfaceToCurrentBounds() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surfaceLayer.position = CGPoint(x: bounds.midX, y: bounds.maxY)
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        updateHover(false)
    }

    func installHostingView(_ hostingView: NSView) {
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func apply(geometry: NotchSurfaceMotionController.Geometry) {
        surfaceGeometry = geometry
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surfaceLayer.backgroundColor = NotchTheme.notchCGColor
        surfaceLayer.isOpaque = true
        surfaceLayer.opacity = 1
        surfaceLayer.bounds = CGRect(
            origin: .zero,
            size: CGSize(width: geometry.width, height: geometry.height)
        )
        surfaceLayer.position = CGPoint(x: bounds.midX, y: bounds.maxY)
        surfaceLayer.cornerRadius = geometry.cornerRadius
        surfaceLayer.transform = CATransform3DIdentity
        CATransaction.commit()
        updateHoverFromCurrentPointer()
    }

    func updateContentsScale(_ scale: CGFloat) {
        let scale = max(1, scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = scale
        surfaceLayer.contentsScale = scale
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard visibleSilhouette.contains(point) else { return nil }
        return super.hitTest(point)
    }

    var visibleSilhouette: NotchSilhouette {
        NotchSilhouette(
            rect: NSRect(
                x: bounds.midX - surfaceGeometry.width / 2,
                y: bounds.maxY - surfaceGeometry.height,
                width: surfaceGeometry.width,
                height: surfaceGeometry.height
            ),
            bottomCornerRadius: surfaceGeometry.cornerRadius
        )
    }

    var renderedSurfaceFrame: CGRect {
        surfaceLayer.frame
    }

    var renderedSurfaceUsesContinuousCorners: Bool {
        surfaceLayer.cornerCurve == .continuous
    }

    private func updateHoverFromCurrentPointer() {
        guard let window else { return }
        updateHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func updateHover(at point: NSPoint) {
        updateHover(visibleSilhouette.contains(point))
    }

    private func updateHover(_ hovered: Bool) {
        guard let changedValue = hoverState.update(hovered) else { return }
        onHoverChange?(changedValue)
    }
}

@MainActor
final class NotchWindowController: NSWindowController {
    private let store: SessionStore
    private let motionState = NotchSurfaceMotionState()
    private let surfaceContainer = NotchSurfaceContainerView(frame: .zero)
    private var cancellables: Set<AnyCancellable> = []
    private var motionController: NotchSurfaceMotionController?
    private var cachedDisplayID: UInt32?

    init(
        store: SessionStore,
        usage: UsageMonitor,
        openSettings: @escaping () -> Void,
        quitApplication: @escaping () -> Void
    ) {
        self.store = store
        let panel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.alphaValue = 1
        panel.acceptsMouseMovedEvents = true
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let hostingView = NSHostingView(
            rootView: NotchRootView(
                store: store,
                usage: usage,
                openSettings: openSettings,
                quitApplication: quitApplication
            )
            .environmentObject(motionState)
        )
        hostingView.wantsLayer = true
        hostingView.canDrawSubviewsIntoLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        hostingView.layer?.drawsAsynchronously = true
        surfaceContainer.installHostingView(hostingView)
        surfaceContainer.onHoverChange = { [weak store] hovered in
            Task { @MainActor in store?.setHovered(hovered) }
        }
        panel.contentView = surfaceContainer
        super.init(window: panel)
        motionController = NotchSurfaceMotionController(state: motionState) { [weak surfaceContainer] geometry in
            surfaceContainer?.apply(geometry: geometry)
        }

        store.$isExpanded
            .removeDuplicates()
            .sink { [weak self] expanded in self?.resize(expanded: expanded, animated: true) }
            .store(in: &cancellables)
        store.$sessions
            .map { [weak store] _ in store?.panelHeight ?? NotchTheme.compactHeight }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.store.isExpanded else { return }
                self.resize(expanded: true, animated: true)
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                self?.cachedDisplayID = nil
                self?.resize(expanded: self?.store.isExpanded ?? false, animated: false)
            }
            .store(in: &cancellables)
        resize(expanded: false, animated: false)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak store] event in
            if event.keyCode == 53 {
                guard store?.isPinned != true else { return event }
                store?.isExpanded = false
                return nil
            }
            return event
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        window?.orderFrontRegardless()
    }

    private func resize(expanded: Bool, animated: Bool) {
        guard let window, let screen = targetScreen() else { return }
        surfaceContainer.updateContentsScale(screen.backingScaleFactor)
        let compactGeometry = NotchSurfaceMotionController.Geometry.compact
        let expandedGeometry = NotchSurfaceMotionController.Geometry(
            width: NotchTheme.expandedWidth,
            height: min(NotchTheme.maximumExpandedHeight, max(96, store.panelHeight)),
            cornerRadius: NotchTheme.expandedCornerRadius
        )
        let targetGeometry = expanded ? expandedGeometry : compactGeometry
        let panelFrame = fixedPanelFrame(on: screen)

        if !animated {
            settleWindow(
                window,
                at: panelFrame,
                geometry: targetGeometry,
                expanded: expanded
            )
        } else {
            // Keep one fixed, centered AppKit window for both states. Only the
            // inner layer changes geometry, so closing cannot inherit a stale
            // origin or shift when a compact window frame is handed off.
            if window.frame != panelFrame {
                setWindowFrame(window, to: panelFrame)
            }
            motionController?.animate(to: targetGeometry, expanded: expanded)
        }
        window.orderFrontRegardless()
    }

    private func setWindowFrame(_ window: NSWindow, to frame: NSRect) {
        window.setFrame(frame, display: false)
        surfaceContainer.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    private func settleWindow(
        _ window: NSWindow,
        at frame: NSRect,
        geometry: NotchSurfaceMotionController.Geometry,
        expanded: Bool
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        window.setFrame(frame, display: false)
        surfaceContainer.layoutSubtreeIfNeeded()
        motionController?.setImmediately(geometry, expanded: expanded)
        window.displayIfNeeded()
        CATransaction.commit()
    }

    private func fixedPanelFrame(on screen: NSScreen) -> NSRect {
        NotchDisplayResolver.fixedPanelFrame(on: descriptor(for: screen))
    }

    private func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        let descriptors = screens.map(descriptor(for:))
        if let cachedDisplayID,
           let connected = NotchDisplayResolver.connectedDisplay(
               id: cachedDisplayID,
               in: descriptors
           ),
           let cached = screens.first(where: { displayID(for: $0) == connected.displayID }) {
            return cached
        }
        guard let selected = NotchDisplayResolver.resolve(descriptors),
              let screen = screens.first(where: { displayID(for: $0) == selected.displayID }) else {
            return nil
        }
        cachedDisplayID = selected.displayID
        return screen
    }

    private func descriptor(for screen: NSScreen) -> NotchDisplayDescriptor {
        NotchDisplayDescriptor(
            displayID: displayID(for: screen),
            frame: screen.frame,
            backingScale: screen.backingScaleFactor,
            hasHardwareNotch: screen.auxiliaryTopLeftArea != nil
                || screen.auxiliaryTopRightArea != nil
                || screen.safeAreaInsets.top > 0,
            isMain: displayID(for: screen) == NSScreen.main.map { displayID(for: $0) }
        )
    }

    private func displayID(for screen: NSScreen) -> UInt32 {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    init(
        store: SessionStore,
        integrations: IntegrationManager,
        usage: UsageMonitor,
        updates: UpdateManager
    ) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 550),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Notch Agents Settings"
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 720, height: 500)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        if !window.setFrameUsingName("NotchAgents.SettingsWindow") {
            window.center()
        }
        window.setFrameAutosaveName("NotchAgents.SettingsWindow")
        window.contentView = NSHostingView(
            rootView: SettingsView(
                integrations: integrations,
                store: store,
                usage: usage,
                updates: updates
            )
        )
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
