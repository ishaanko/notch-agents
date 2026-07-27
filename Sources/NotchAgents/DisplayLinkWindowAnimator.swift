import AppKit
import Combine
import CoreVideo
import QuartzCore

/// The single animation timeline shared by AppKit geometry and SwiftUI content.
///
/// `progress` is intentionally display-linked. Views should derive opacity and
/// top-anchored scale from it instead of starting a second implicit animation.
@MainActor
final class NotchSurfaceMotionState: ObservableObject {
    @Published private(set) var progress: CGFloat = 0
    @Published private(set) var isExpanded = false
    @Published private(set) var reduceMotion = false
    @Published private(set) var geometry = NotchSurfaceMotionController.Geometry.compact

    fileprivate func update(
        progress: CGFloat,
        isExpanded: Bool,
        reduceMotion: Bool,
        geometry: NotchSurfaceMotionController.Geometry
    ) {
        self.progress = progress
        self.isExpanded = isExpanded
        self.reduceMotion = reduceMotion
        self.geometry = geometry
    }
}

/// Display-linked, interruptible spring motion for the persistent notch layer.
///
/// The display-link callback only schedules a main-thread integration step.
/// It never mutates the window frame. Window geometry is changed by
/// `NotchWindowController` only at transition boundaries.
@MainActor
final class NotchSurfaceMotionController {
    struct Geometry: Equatable {
        var width: CGFloat
        var height: CGFloat
        var cornerRadius: CGFloat

        static let compact = Geometry(
            width: NotchTheme.compactWidth,
            height: NotchTheme.compactHeight,
            cornerRadius: NotchTheme.compactCornerRadius
        )
    }

    let state: NotchSurfaceMotionState

    private let applyGeometry: (Geometry) -> Void
    private var displayLink: CVDisplayLink?
    private var width = SpringScalar(value: Double(Geometry.compact.width))
    private var height = SpringScalar(value: Double(Geometry.compact.height))
    private var progress = SpringScalar(value: 0)
    private var targetGeometry = Geometry.compact
    private var targetExpanded = false
    private var response = NotchTheme.openResponse
    private var isRunning = false
    private var lastHostTime: UInt64 = 0
    private var lastDeliveredHostTime: UInt64 = 0
    private var completion: (() -> Void)?

    private var reducedFadeStart: CGFloat = 0
    private var reducedFadeElapsed: TimeInterval = 0
    private var reducedFadeDuration: TimeInterval = 0.2
    private var isReducedFade = false

    init(
        state: NotchSurfaceMotionState,
        applyGeometry: @escaping (Geometry) -> Void
    ) {
        self.state = state
        self.applyGeometry = applyGeometry

        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess,
              let link else {
            return
        }
        displayLink = link
        CVDisplayLinkSetOutputCallback(
            link,
            Self.displayLinkCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    deinit {
        if let displayLink, CVDisplayLinkIsRunning(displayLink) {
            CVDisplayLinkStop(displayLink)
        }
    }

    func setImmediately(_ geometry: Geometry, expanded: Bool) {
        stop()
        targetGeometry = geometry
        targetExpanded = expanded
        width.set(Double(geometry.width))
        height.set(Double(geometry.height))
        progress.set(expanded ? 1 : 0)
        let currentGeometry = applyCurrentGeometry()
        state.update(
            progress: expanded ? 1 : 0,
            isExpanded: expanded,
            reduceMotion: shouldReduceMotion,
            geometry: currentGeometry
        )
        let callback = completion
        completion = nil
        callback?()
    }

    /// Changes only the spring target. Current values and velocity are retained,
    /// so hover reversals do not stop or jump.
    func animate(
        to geometry: Geometry,
        expanded: Bool,
        completion: (() -> Void)? = nil
    ) {
        targetGeometry = geometry
        targetExpanded = expanded
        self.completion = completion

        let targetProgress = expanded ? 1.0 : 0.0
        width.target = Double(geometry.width)
        height.target = Double(geometry.height)
        progress.target = targetProgress

        guard displayLink != nil else {
            setImmediately(geometry, expanded: expanded)
            return
        }

        response = (expanded ? NotchTheme.openResponse : NotchTheme.closeResponse) / animationSpeed

        if shouldReduceMotion {
            width.set(Double(geometry.width))
            height.set(Double(geometry.height))
            reducedFadeStart = CGFloat(progress.value)
            reducedFadeElapsed = 0
            reducedFadeDuration = max(0.04, 0.2 * abs(CGFloat(targetProgress) - reducedFadeStart))
            isReducedFade = true
        } else {
            isReducedFade = false
        }

        let currentGeometry = applyCurrentGeometry()
        state.update(
            progress: CGFloat(progress.value),
            isExpanded: expanded,
            reduceMotion: shouldReduceMotion,
            geometry: currentGeometry
        )
        start()
    }

    private var animationSpeed: Double {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "notchAgents.animationSpeed") != nil else { return 1 }
        return max(0.65, min(1.35, defaults.double(forKey: "notchAgents.animationSpeed")))
    }

    private var shouldReduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || Self.animationFPS == 0
    }

    private func start() {
        guard let displayLink else { return }
        isRunning = true
        lastHostTime = 0
        lastDeliveredHostTime = 0
        if !CVDisplayLinkIsRunning(displayLink) {
            CVDisplayLinkStart(displayLink)
        }
    }

    private func stop() {
        isRunning = false
        if let displayLink, CVDisplayLinkIsRunning(displayLink) {
            CVDisplayLinkStop(displayLink)
        }
        lastHostTime = 0
        lastDeliveredHostTime = 0
    }

    private nonisolated func scheduleStep(hostTime: UInt64) {
        Task { @MainActor [weak self] in
            self?.step(hostTime: hostTime)
        }
    }

    private func step(hostTime: UInt64) {
        guard isRunning else { return }
        let configuredFPS = Self.animationFPS
        let preferredFPS = configuredFPS == 0 ? 60 : configuredFPS

        let minimumTicks = UInt64(CVGetHostClockFrequency() / Double(preferredFPS == 60 ? 60 : 120))
        guard lastDeliveredHostTime == 0 || hostTime - lastDeliveredHostTime >= minimumTicks else {
            return
        }
        lastDeliveredHostTime = hostTime

        guard lastHostTime != 0 else {
            lastHostTime = hostTime
            publishCurrentFrame()
            return
        }

        let rawDelta = Double(hostTime - lastHostTime) / CVGetHostClockFrequency()
        lastHostTime = hostTime
        let delta = min(max(rawDelta, 1.0 / 240.0), 1.0 / 30.0)

        if isReducedFade {
            stepReducedFade(delta: delta)
        } else {
            stepSpring(delta: delta)
        }
    }

    private func stepSpring(delta: TimeInterval) {
        // `response` follows Apple's designer-facing spring parameter. A
        // critically damped spring has no scripted duration and stays
        // interruptible because each frame begins at the live value/velocity.
        let angularFrequency = (2 * Double.pi) / max(0.08, response)
        width.step(delta: delta, angularFrequency: angularFrequency)
        height.step(delta: delta, angularFrequency: angularFrequency)
        progress.step(delta: delta, angularFrequency: angularFrequency)
        publishCurrentFrame()

        guard width.isSettled(positionTolerance: 0.08, velocityTolerance: 0.25),
              height.isSettled(positionTolerance: 0.08, velocityTolerance: 0.25),
              progress.isSettled(positionTolerance: 0.0008, velocityTolerance: 0.008) else {
            return
        }
        width.finish()
        height.finish()
        progress.finish()
        finish()
    }

    private func stepReducedFade(delta: TimeInterval) {
        reducedFadeElapsed += delta
        let fraction = min(1, reducedFadeElapsed / reducedFadeDuration)
        let eased = fraction * fraction * (3 - 2 * fraction)
        let target: CGFloat = targetExpanded ? 1 : 0
        progress.value = Double(reducedFadeStart + (target - reducedFadeStart) * CGFloat(eased))
        progress.velocity = 0
        publishCurrentFrame()
        if fraction >= 1 {
            progress.set(Double(target))
            finish()
        }
    }

    private func publishCurrentFrame() {
        let currentGeometry = applyCurrentGeometry()
        state.update(
            progress: CGFloat(progress.value),
            isExpanded: targetExpanded,
            reduceMotion: shouldReduceMotion,
            geometry: currentGeometry
        )
    }

    @discardableResult
    private func applyCurrentGeometry() -> Geometry {
        let normalizedProgress = CGFloat(min(1, max(0, progress.value)))
        let cornerRadius = NotchTheme.compactCornerRadius
            + (NotchTheme.expandedCornerRadius - NotchTheme.compactCornerRadius) * normalizedProgress
        let geometry = Geometry(
            width: CGFloat(width.value),
            height: CGFloat(height.value),
            cornerRadius: cornerRadius
        )
        applyGeometry(geometry)
        return geometry
    }

    private func finish() {
        stop()
        let currentGeometry = applyCurrentGeometry()
        state.update(
            progress: targetExpanded ? 1 : 0,
            isExpanded: targetExpanded,
            reduceMotion: shouldReduceMotion,
            geometry: currentGeometry
        )
        let callback = completion
        completion = nil
        callback?()
    }

    private static let displayLinkCallback: CVDisplayLinkOutputCallback = {
        _, _, outputTime, _, _, context in
        guard let context else { return kCVReturnError }
        let controller = Unmanaged<NotchSurfaceMotionController>
            .fromOpaque(context)
            .takeUnretainedValue()
        controller.scheduleStep(hostTime: outputTime.pointee.hostTime)
        return kCVReturnSuccess
    }

    private static var animationFPS: Int {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "notchAgents.animationFPS") == nil
            ? 60
            : defaults.integer(forKey: "notchAgents.animationFPS")
    }
}

private struct SpringScalar {
    var value: Double
    var velocity: Double = 0
    var target: Double

    init(value: Double) {
        self.value = value
        target = value
    }

    mutating func set(_ newValue: Double) {
        value = newValue
        target = newValue
        velocity = 0
    }

    mutating func step(delta: TimeInterval, angularFrequency: Double) {
        let displacement = value - target
        let velocityTerm = velocity + angularFrequency * displacement
        let decay = exp(-angularFrequency * delta)
        let nextDisplacement = (displacement + velocityTerm * delta) * decay
        let nextVelocity = (velocity - angularFrequency * velocityTerm * delta) * decay

        // Retargeting retains velocity, but the critically damped presentation
        // value must not visibly cross its resting target.
        if displacement != 0, displacement.sign != nextDisplacement.sign {
            finish()
        } else {
            value = target + nextDisplacement
            velocity = nextVelocity
        }
    }

    mutating func finish() {
        value = target
        velocity = 0
    }

    func isSettled(positionTolerance: Double, velocityTolerance: Double) -> Bool {
        abs(value - target) <= positionTolerance && abs(velocity) <= velocityTolerance
    }
}
