import SwiftUI

// Native SwiftUI port inspired by Jakub Antalik's MIT-licensed border-beam:
// https://github.com/Jakubantalik/border-beam

struct CompletionBorderBeam: View {
    let token: String
    var cornerRadius: CGFloat = 12
    var onFinished: () -> Void
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.notchReduceMotion) private var appReduceMotion
    @State private var start = Date()
    @State private var finished = false

    var body: some View {
        let reduceMotion = systemReduceMotion || appReduceMotion
        Group {
            if reduceMotion {
                staticFlash
            } else {
                TimelineView(.animation(paused: finished)) { context in
                    let elapsed = max(0, context.date.timeIntervalSince(start))
                    let circuit = min(1, elapsed / 1.35)
                    let fade = elapsed <= 1.35 ? 1 : max(0, 1 - (elapsed - 1.35) / 0.18)
                    beam(angle: .degrees(circuit * 360), opacity: fade)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: token) {
            start = Date()
            finished = false
            let duration = reduceMotion ? 0.2 : 1.53
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            finished = true
            onFinished()
        }
    }

    private var staticFlash: some View {
        notchShape
            .strokeBorder(.white.opacity(0.55), lineWidth: 1)
            .mask(endpointFade)
            .transition(.opacity)
    }

    private func beam(angle: Angle, opacity: Double) -> some View {
        let gradient = AngularGradient(
            stops: [
                .init(color: .clear, location: 0.00),
                .init(color: .clear, location: 0.70),
                .init(color: .white.opacity(0.12), location: 0.82),
                .init(color: .white, location: 0.91),
                .init(color: .white.opacity(0.14), location: 0.97),
                .init(color: .clear, location: 1.00),
            ],
            center: .center,
            angle: angle
        )
        return ZStack {
            notchShape
                .strokeBorder(gradient, lineWidth: 1)
            notchShape
                .inset(by: 3)
                .strokeBorder(gradient, lineWidth: 2)
                .blur(radius: 2.5)
                .opacity(0.28)
        }
        .mask(endpointFade)
        .opacity(opacity)
    }

    private var notchShape: NotchSurfaceShape {
        NotchSurfaceShape(cornerRadius: cornerRadius)
    }

    /// Feather both open endpoints where the software surface meets the
    /// physical notch instead of stopping the beam on a hard pixel.
    private var endpointFade: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 2)
            LinearGradient(
                colors: [.clear, .white],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 8)
            Color.white
        }
    }
}
