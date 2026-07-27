import AppKit

// Static AppKit renderer based on Jakub Antalik's MIT-licensed thinking-orbs engine:
// https://github.com/Jakubantalik/thinking-orbs
// The projector, deterministic lattices, resolved 20pt profiles, motion
// cycles, depth ink and far-to-near painter follow the source implementation.

enum ThinkingOrbState: String, CaseIterable, Sendable {
    case working, searching, solving, listening, composing, shaping
}

struct ThinkingOrbPreset: Equatable, Sendable {
    var speed: Double
    var count: Double
    var radius: Double
    var scan: Double?
    var dim: Double?
    var band: Double?
    var spread: Double?

    static let presets: [ThinkingOrbState: ThinkingOrbPreset] = [
        .working: .init(speed: 3.9, count: 0.238, radius: 2.4),
        .searching: .init(speed: 2.665, count: 0.105, radius: 1.75, scan: 4.335, dim: 0.45),
        .solving: .init(speed: 1.95, count: 0.088, radius: 1.9),
        .listening: .init(speed: 3.998, count: 0.105, radius: 1.6),
        .composing: .init(speed: 3.12, count: 0.051, radius: 1.073, band: 4.94),
        .shaping: .init(speed: 2.08, count: 0.53, radius: 1.011, spread: 1.45),
    ]
}

enum ThinkingOrbMenuBarIcon {
    /// Returns a template `NSImage` suitable for `NSStatusItem.button?.image`.
    @MainActor
    static func makeImage(pointSize: CGFloat = 18) -> NSImage {
        let side = max(10, pointSize)
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSGraphicsContext.current?.shouldAntialias = true

        let dots = ThinkingOrbRenderer.dots(
            state: .working,
            time: 0.6,
            size: side
        )
        for dot in dots.sorted(by: { $0.z < $1.z }) where dot.alpha >= 0.05 {
            let radius = max(0.45, dot.radius)
            let rect = NSRect(
                x: dot.x - radius,
                y: side - dot.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            NSColor(calibratedWhite: 0, alpha: min(1, max(0.16, dot.alpha))).setFill()
            NSBezierPath(ovalIn: rect).fill()
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

struct OrbDot: Equatable, Sendable {
    var x: CGFloat
    var y: CGFloat
    var z: CGFloat
    var radius: CGFloat
    var white: Double
    var alpha: Double = 1
}

struct ThinkingOrbResolvedCounts: Equatable, Sendable {
    var orbitN = 0
    var ghostN = 0
    var particles = 0
    var latRings = 0
    var lonDensity = 0
    var rings = 0
    var lanes = 0
    var segments = 0
    var morphDots = 0
}

enum ThinkingOrbRenderer {
    private struct Projection {
        var x: Double
        var y: Double
        var z: Double
    }

    private struct Move {
        var axis: Int
        var lo: Double
        var hi: Double
        var angle: Double
    }

    private struct SolveState {
        var amount: [Double]
        var active: Int
    }

    private typealias Point2 = SIMD2<Double>
    private typealias Path2 = (Double) -> Point2

    static func dots(state: ThinkingOrbState, time: TimeInterval, size: CGFloat = 20) -> [OrbDot] {
        let speed = ThinkingOrbPreset.presets[state]!.speed
        let sourceTime = time * speed
        return switch state {
        case .working: orbits(time: sourceTime, size: size)
        case .searching: globe(time: sourceTime, size: size)
        case .solving: rubik(time: sourceTime, size: size)
        case .listening: wave(time: sourceTime, size: size)
        case .composing: ribbon(time: sourceTime, size: size)
        case .shaping: morph(time: sourceTime, size: size)
        }
    }

    // MARK: Source core.ts

    static func hashD(_ a: Double, _ b: Double) -> Double {
        let h = sin(a * 12.9898 + b * 78.233) * 43_758.5453
        return h - floor(h)
    }

    static func fibonacciDirection(index: Int, count: Int) -> SIMD3<Double> {
        let golden = Double.pi * (3 - sqrt(5))
        let y = 1 - (2 * (Double(index) + 0.5)) / Double(count)
        let radial = sqrt(max(0, 1 - y * y))
        let angle = Double(index) * golden
        return SIMD3(radial * cos(angle), y, radial * sin(angle))
    }

    static func angleDelta(_ a: Double, _ b: Double) -> Double {
        atan2(sin(a - b), cos(a - b))
    }

    static func radiusScale(size: Double, power: Double) -> Double {
        pow(size / 300, power)
    }

    static func resolvedCounts(for state: ThinkingOrbState) -> ThinkingOrbResolvedCounts {
        let preset = ThinkingOrbPreset.presets[state]!
        let root = sqrt(preset.count)
        switch state {
        case .working:
            return ThinkingOrbResolvedCounts(
                orbitN: max(1, Int((12 * preset.count).rounded())),
                ghostN: max(1, Int((40 * preset.count).rounded())),
                particles: 3
            )
        case .searching:
            return ThinkingOrbResolvedCounts(
                latRings: max(2, Int((17 * root).rounded())),
                lonDensity: max(2, Int((44 * root).rounded()))
            )
        case .solving:
            return ThinkingOrbResolvedCounts(
                latRings: max(2, Int((15 * root).rounded())),
                lonDensity: max(2, Int((40 * root).rounded()))
            )
        case .listening:
            return ThinkingOrbResolvedCounts(
                lonDensity: max(2, Int((40 * root).rounded())),
                rings: max(2, Int((15 * root).rounded()))
            )
        case .composing:
            let baseLanes = max(2, Int((5 * root).rounded()))
            return ThinkingOrbResolvedCounts(
                ghostN: max(1, Int((150 * preset.count).rounded())),
                lanes: max(1, Int((Double(baseLanes) * (preset.band ?? 1)).rounded())),
                segments: max(2, Int((88 * root).rounded()))
            )
        case .shaping:
            return ThinkingOrbResolvedCounts(morphDots: max(6, Int((34 * preset.count).rounded())))
        }
    }

    private static func project(
        _ point: SIMD3<Double>,
        yaw: Double,
        tilt: Double,
        center: Double,
        scale: Double
    ) -> Projection {
        let st = sin(tilt), ct = cos(tilt)
        let sy = sin(yaw), cy = cos(yaw)
        let x1 = point.x * cy + point.z * sy
        let z1 = -point.x * sy + point.z * cy
        let y1 = point.y * ct - z1 * st
        let z2 = point.y * st + z1 * ct
        return Projection(x: center + x1 * scale, y: center - y1 * scale, z: z2)
    }

    // MARK: Source orbits.ts

    private static func orbits(time: Double, size: CGFloat) -> [OrbDot] {
        let preset = ThinkingOrbPreset.presets[.working]!
        let counts = resolvedCounts(for: .working)
        let center = Double(size) / 2
        let outerRadius = center * 0.82
        let radiusScale = radiusScale(size: Double(size), power: 0.6)
        let ghostRadius = 0.9 * preset.radius
        let particleRadius = 1.2 * preset.radius
        let particleDepthRadius = 1.6 * preset.radius
        var dots: [OrbDot] = []

        for orbit in 0..<counts.orbitN {
            let h1 = hashD(Double(orbit), 1.7)
            let h2 = hashD(Double(orbit), 5.2)
            let h3 = hashD(Double(orbit), 8.9)
            let orbitRadius = outerRadius * (0.45 + 0.52 * h1)
            let theta = h1 * 2 * .pi
            let phi = acos(2 * h2 - 1)
            let nx = sin(phi) * cos(theta)
            let ny = cos(phi)
            let nz = sin(phi) * sin(theta)
            var ux = -ny
            var uy = nx
            let uz = 0.0
            let length = max(1e-6, sqrt(ux * ux + uy * uy))
            ux /= length
            uy /= length
            let vx = ny * uz - nz * uy
            let vy = nz * ux - nx * uz
            let vz = nx * uy - ny * ux
            let velocity = (0.25 + 0.55 * h3) * (h3 > 0.5 ? 1 : -1)

            for ghost in 0..<counts.ghostN {
                let angle = (Double(ghost) / Double(counts.ghostN)) * 2 * .pi
                let point = SIMD3(
                    (ux * cos(angle) + vx * sin(angle)) * orbitRadius,
                    (uy * cos(angle) + vy * sin(angle)) * orbitRadius,
                    (uz * cos(angle) + vz * sin(angle)) * orbitRadius
                )
                let projected = project(point, yaw: time * 0.12, tilt: 0.3, center: center, scale: 1)
                let depth = (projected.z / orbitRadius + 1) / 2
                dots.append(OrbDot(
                    x: projected.x,
                    y: projected.y,
                    z: projected.z,
                    radius: ghostRadius * radiusScale,
                    white: 0.72,
                    alpha: 0.5 * (0.4 + 0.6 * depth)
                ))
            }

            for particle in 0..<counts.particles {
                let angle = time * velocity
                    + (Double(particle) / Double(counts.particles)) * 2 * .pi
                    + h2 * 6
                let point = SIMD3(
                    (ux * cos(angle) + vx * sin(angle)) * orbitRadius,
                    (uy * cos(angle) + vy * sin(angle)) * orbitRadius,
                    (uz * cos(angle) + vz * sin(angle)) * orbitRadius
                )
                let projected = project(point, yaw: time * 0.12, tilt: 0.3, center: center, scale: 1)
                let depth = (projected.z / orbitRadius + 1) / 2
                dots.append(OrbDot(
                    x: projected.x,
                    y: projected.y,
                    z: projected.z,
                    radius: (particleRadius + particleDepthRadius * depth) * radiusScale,
                    white: 0.3 - 0.22 * depth
                ))
            }
        }
        return dots
    }

    // MARK: Source lattice.ts

    private static func globe(time: Double, size: CGFloat) -> [OrbDot] {
        let preset = ThinkingOrbPreset.presets[.searching]!
        let counts = resolvedCounts(for: .searching)
        let center = Double(size) / 2
        let radius = center * 0.82
        let spin = 0.5
        let tilt = 0.4 + 0.06 * sin(time * 0.35)
        let scan = time * (spin + (1.7 - spin) * (preset.scan ?? 1))
        let rs = radiusScale(size: Double(size), power: 0.6)
        let rBase = 0.6 * preset.radius
        let rDepth = 1.7 * preset.radius
        var dots: [OrbDot] = []

        for ring in 0...counts.latRings {
            let latitude = -.pi / 2 + (Double(ring) / Double(counts.latRings)) * .pi
            let cosLat = cos(latitude)
            let sinLat = sin(latitude)
            let longitudeCount = max(1, Int((abs(cosLat) * Double(counts.lonDensity)).rounded()))
            for longitudeIndex in 0..<longitudeCount {
                let longitude = (Double(longitudeIndex) / Double(longitudeCount)) * 2 * .pi
                let projected = project(
                    SIMD3(cosLat * cos(longitude), sinLat, cosLat * sin(longitude)),
                    yaw: time * spin,
                    tilt: tilt,
                    center: center,
                    scale: radius
                )
                let depth = (projected.z + 1) / 2
                let delta = angleDelta(longitude + time * spin, scan)
                let boost = exp(-(delta * delta) / 0.18) * max(0, projected.z)
                dots.append(OrbDot(
                    x: projected.x,
                    y: projected.y,
                    z: projected.z,
                    radius: (rBase + rDepth * depth + boost) * rs,
                    white: 0.62 - 0.54 * depth,
                    alpha: (preset.dim ?? 1) + (1 - (preset.dim ?? 1)) * min(1, boost)
                ))
            }
        }
        return dots
    }

    private static func makeMoves(count: Int) -> [Move] {
        (0..<count).map { index in
            let axis = min(2, Int(floor(hashD(Double(index), 2.3) * 3)))
            let lo = -1 + 0.5 * Double(min(3, Int(floor(hashD(Double(index), 5.9) * 4))))
            let direction = hashD(Double(index), 7.7) < 0.5 ? 1.0 : -1.0
            return Move(axis: axis, lo: lo, hi: lo + 0.5, angle: direction * .pi / 2)
        }
    }

    private static func solveCycle(time: Double, count: Int, slotDuration: Double, rest: Double) -> SolveState {
        let cycle = 2 * Double(count) * slotDuration + rest
        let cycleTime = time.truncatingRemainder(dividingBy: cycle)
        var amount = Array(repeating: 0.0, count: count)
        var active = -1
        if cycleTime < 2 * Double(count) * slotDuration {
            let slot = Int(floor(cycleTime / slotDuration))
            let progress = (cycleTime - Double(slot) * slotDuration) / slotDuration
            let clamped = min(1, progress / 0.7)
            let eased = 1 - pow(1 - clamped, 3)
            if slot < count {
                if slot > 0 {
                    for index in 0..<slot { amount[index] = 1 }
                }
                amount[slot] = eased
                active = slot
            } else {
                let reverse = 2 * count - 1 - slot
                if reverse > 0 {
                    for index in 0..<reverse { amount[index] = 1 }
                }
                amount[reverse] = 1 - eased
                active = reverse
            }
        }
        return SolveState(amount: amount, active: active)
    }

    private static func applyMoves(
        _ original: SIMD3<Double>,
        moves: [Move],
        state: SolveState
    ) -> (SIMD3<Double>, Bool) {
        var point = original
        var inActive = false
        for index in moves.indices where state.amount[index] > 0 {
            let move = moves[index]
            let coordinate = move.axis == 0 ? point.x : (move.axis == 1 ? point.y : point.z)
            guard coordinate >= move.lo, coordinate < move.hi else { continue }
            if index == state.active { inActive = true }
            let angle = move.angle * state.amount[index]
            let cosine = cos(angle), sine = sin(angle)
            if move.axis == 0 {
                let y = point.y * cosine - point.z * sine
                point.z = point.y * sine + point.z * cosine
                point.y = y
            } else if move.axis == 1 {
                let x = point.x * cosine + point.z * sine
                point.z = -point.x * sine + point.z * cosine
                point.x = x
            } else {
                let x = point.x * cosine - point.y * sine
                point.y = point.x * sine + point.y * cosine
                point.x = x
            }
        }
        return (point, inActive)
    }

    private static func rubik(time: Double, size: CGFloat) -> [OrbDot] {
        let preset = ThinkingOrbPreset.presets[.solving]!
        let counts = resolvedCounts(for: .solving)
        let center = Double(size) / 2
        let radius = center * 0.82
        let rs = radiusScale(size: Double(size), power: 0.6)
        let moves = makeMoves(count: 14)
        let solve = solveCycle(time: time, count: 14, slotDuration: 0.42, rest: 1.2)
        let rBase = 0.6 * preset.radius
        let rDepth = 1.7 * preset.radius
        let rActive = 0.3 * preset.radius
        var dots: [OrbDot] = []

        for ring in 0...counts.latRings {
            let latitude = -.pi / 2 + (Double(ring) / Double(counts.latRings)) * .pi
            let cosLat = cos(latitude), sinLat = sin(latitude)
            let longitudeCount = max(1, Int((abs(cosLat) * Double(counts.lonDensity)).rounded()))
            for longitudeIndex in 0..<longitudeCount {
                let longitude = (Double(longitudeIndex) / Double(longitudeCount)) * 2 * .pi
                let (moved, active) = applyMoves(
                    SIMD3(cosLat * cos(longitude), sinLat, cosLat * sin(longitude)),
                    moves: moves,
                    state: solve
                )
                let projected = project(
                    moved,
                    yaw: time * 0.55,
                    tilt: 0.35 + 0.1 * sin(time * 0.9),
                    center: center,
                    scale: radius
                )
                let depth = (projected.z + 1) / 2
                dots.append(OrbDot(
                    x: projected.x,
                    y: projected.y,
                    z: projected.z,
                    radius: (rBase + rDepth * depth + (active ? rActive : 0)) * rs,
                    white: 0.62 - 0.54 * depth - (active ? 0.14 : 0)
                ))
            }
        }
        return dots
    }

    private static func wave(time: Double, size: CGFloat) -> [OrbDot] {
        let preset = ThinkingOrbPreset.presets[.listening]!
        let counts = resolvedCounts(for: .listening)
        let center = Double(size) / 2
        let outerRadius = center * 0.874
        let rs = radiusScale(size: Double(size), power: 0.6)
        let rBase = 0.6 * preset.radius
        let rDepth = 1.7 * preset.radius
        var dots: [OrbDot] = []

        for ring in 0...counts.rings {
            let latitude = -.pi / 2 + (Double(ring) / Double(counts.rings)) * .pi
            let cosLat = cos(latitude), sinLat = sin(latitude)
            let wave = 0.62 * sin(time * 2.1 - Double(ring) * 0.52)
                + 0.38 * sin(time * 1.27 + Double(ring) * 0.83)
            let radius = outerRadius * (0.88 + 0.105 * wave)
            let longitudeCount = max(1, Int((abs(cosLat) * Double(counts.lonDensity)).rounded()))
            for longitudeIndex in 0..<longitudeCount {
                let longitude = (Double(longitudeIndex) / Double(longitudeCount)) * 2 * .pi
                let projected = project(
                    SIMD3(
                        cosLat * cos(longitude) * radius,
                        sinLat * radius,
                        cosLat * sin(longitude) * radius
                    ),
                    yaw: time * 0.18,
                    tilt: 0.38,
                    center: center,
                    scale: 1
                )
                let depth = (projected.z / outerRadius + 1) / 2
                let crest = max(0, wave)
                dots.append(OrbDot(
                    x: projected.x,
                    y: projected.y,
                    z: projected.z,
                    radius: (rBase + rDepth * depth) * (1 + 0.4 * crest) * rs,
                    white: 0.66 - 0.56 * depth - 0.1 * crest
                ))
            }
        }
        return dots
    }

    // MARK: Source ribbon.ts

    private static func ribbon(time: Double, size: CGFloat) -> [OrbDot] {
        let preset = ThinkingOrbPreset.presets[.composing]!
        let counts = resolvedCounts(for: .composing)
        let center = Double(size) / 2
        let radius = center * 0.78
        let spin = 0.0
        let rs = radiusScale(size: Double(size), power: 0.6)
        let rBase = 1.1 * preset.radius
        let rDepth = 1.7 * preset.radius
        var dots: [OrbDot] = []

        for index in 0..<counts.ghostN {
            let direction = fibonacciDirection(index: index, count: counts.ghostN)
            let projected = project(
                direction * radius,
                yaw: time * 0.1 * spin,
                tilt: 0.3,
                center: center,
                scale: 1
            )
            let depth = (projected.z / radius + 1) / 2
            dots.append(OrbDot(
                x: projected.x,
                y: projected.y,
                z: projected.z,
                radius: 0.8 * rs,
                white: 0.78,
                alpha: 0.1 + 0.22 * depth
            ))
        }

        let yaw = time * 0.24 * spin
        let tilt = 0.55 + 0.3 * sin(time * 0.18) * spin
        let u = SIMD3(cos(yaw), 0.0, sin(yaw))
        let v = SIMD3(-u.z * sin(tilt), cos(tilt), u.x * sin(tilt))
        let normal = cross(u, v)
        for lane in 0..<counts.lanes {
            let laneOffset = (Double(lane) - Double(counts.lanes - 1) / 2) * 0.075
            let edge = abs(Double(lane) - Double(counts.lanes - 1) / 2)
                / max(1, Double(counts.lanes - 1) / 2)
            for segment in 0..<counts.segments {
                let angle = (Double(segment) / Double(counts.segments)) * 2 * .pi
                let wobble = 0.16 * sin(angle * 3 - time * 1.7 + Double(lane) * 0.22)
                    + 0.07 * sin(angle * 5 + time * 1.1)
                let point = u * cos(angle) + v * sin(angle) + normal * (laneOffset + wobble)
                let normalized = point / simdLength(point)
                let projected = project(
                    normalized * radius,
                    yaw: time * 0.1 * spin,
                    tilt: 0.3,
                    center: center,
                    scale: 1
                )
                let depth = (projected.z / radius + 1) / 2
                dots.append(OrbDot(
                    x: projected.x,
                    y: projected.y,
                    z: projected.z,
                    radius: (rBase + rDepth * depth) * (1 - 0.25 * edge) * rs,
                    white: 0.52 - 0.44 * depth + 0.18 * edge,
                    alpha: 0.4 + 0.6 * depth
                ))
            }
        }
        return dots
    }

    private static func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(
            a.y * b.z - a.z * b.y,
            a.z * b.x - a.x * b.z,
            a.x * b.y - a.y * b.x
        )
    }

    private static func simdLength(_ point: SIMD3<Double>) -> Double {
        sqrt(point.x * point.x + point.y * point.y + point.z * point.z)
    }

    // MARK: Source morph.ts

    static let morphHold = 1.4
    static let morphDuration = 0.9

    static func morphBlend(atSourceTime time: Double) -> Double {
        let segment = morphHold + morphDuration
        let local = time.truncatingRemainder(dividingBy: segment)
        guard local > morphHold else { return 0 }
        let value = (local - morphHold) / morphDuration
        return value * value * (3 - 2 * value)
    }

    private static func morph(time: Double, size: CGFloat) -> [OrbDot] {
        let preset = ThinkingOrbPreset.presets[.shaping]!
        let counts = resolvedCounts(for: .shaping)
        let segmentDuration = morphHold + morphDuration
        let cycleTime = time.truncatingRemainder(dividingBy: segmentDuration * 3)
        let shapeIndex = Int(floor(cycleTime / segmentDuration))
        let local = cycleTime - Double(shapeIndex) * segmentDuration
        let blend: Double
        if local > morphHold {
            let value = (local - morphHold) / morphDuration
            blend = value * value * (3 - 2 * value)
        } else {
            blend = 0
        }
        let paths = morphPaths()
        let pathA = paths[shapeIndex]
        let pathB = paths[(shapeIndex + 1) % paths.count]
        let spread = preset.spread ?? 1
        let samples = 160
        var blended: [Point2] = []
        for index in 0..<samples {
            let fraction = Double(index) / Double(samples)
            let a = pathA(fraction)
            let b = pathB(fraction)
            blended.append((a + (b - a) * blend) * spread)
        }

        var lengths: [Double] = []
        var total = 0.0
        for index in 0..<samples {
            let length = simdLength(blended[(index + 1) % samples] - blended[index])
            lengths.append(length)
            total += length
        }

        let radius = 0.021 * preset.radius * 1.35 * spread
        let pulse = 1 + 0.02 * sin(local * 3.1)
        let center = Double(size) / 2
        var segment = 0
        var accumulated = 0.0
        var dots: [OrbDot] = []
        for index in 0..<counts.morphDots {
            let target = (Double(index) / Double(counts.morphDots)) * total
            while segment < samples - 1, accumulated + lengths[segment] < target {
                accumulated += lengths[segment]
                segment += 1
            }
            let a = blended[segment]
            let b = blended[(segment + 1) % samples]
            let fraction = lengths[segment] > 0
                ? min(1, (target - accumulated) / lengths[segment])
                : 0
            let point = (a + (b - a) * fraction) * pulse
            dots.append(OrbDot(
                x: center + point.x * Double(size),
                y: center + point.y * Double(size),
                z: 0,
                radius: max(0.35, radius * Double(size)),
                white: 0.1
            ))
        }
        return dots
    }

    private static func morphPaths() -> [Path2] {
        let circle: Path2 = { fraction in
            let angle = -.pi / 2 + fraction * 2 * .pi
            return Point2(cos(angle) * 0.24, sin(angle) * 0.24)
        }
        let triangle = polygonPath([
            Point2(0, -0.26), Point2(0.24, 0.16), Point2(-0.24, 0.16),
        ])
        let square = polygonPath([
            Point2(0, -0.2), Point2(0.2, -0.2), Point2(0.2, 0.2),
            Point2(-0.2, 0.2), Point2(-0.2, -0.2),
        ])
        return [circle, triangle, square]
    }

    private static func polygonPath(_ vertices: [Point2]) -> Path2 {
        var lengths: [Double] = []
        var total = 0.0
        for index in vertices.indices {
            let length = simdLength(vertices[(index + 1) % vertices.count] - vertices[index])
            lengths.append(length)
            total += length
        }
        return { fraction in
            var target = fraction * total
            var index = 0
            while index < vertices.count - 1, target > lengths[index] {
                target -= lengths[index]
                index += 1
            }
            let a = vertices[index]
            let b = vertices[(index + 1) % vertices.count]
            let progress = lengths[index] > 0 ? min(1, target / lengths[index]) : 0
            return a + (b - a) * progress
        }
    }

    private static func simdLength(_ point: SIMD2<Double>) -> Double {
        sqrt(point.x * point.x + point.y * point.y)
    }
}
