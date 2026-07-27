import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: 1024,
    pixelsHigh: 1024,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    exit(1)
}
bitmap.size = NSSize(width: 1024, height: 1024)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

let background = NSBezierPath(
    roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896),
    xRadius: 210,
    yRadius: 210
)
let backgroundColor = NSColor(
    calibratedRed: 0.18,
    green: 0.31,
    blue: 0.45,
    alpha: 1
)
backgroundColor.setFill()
background.fill()

func stroke(_ path: NSBezierPath, width: CGFloat = 56) {
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    NSColor.white.setStroke()
    path.stroke()
}

let branches = NSBezierPath()
branches.move(to: NSPoint(x: 512, y: 635))
branches.line(to: NSPoint(x: 512, y: 520))
branches.move(to: NSPoint(x: 512, y: 540))
branches.curve(
    to: NSPoint(x: 338, y: 390),
    controlPoint1: NSPoint(x: 474, y: 490),
    controlPoint2: NSPoint(x: 388, y: 468)
)
branches.move(to: NSPoint(x: 512, y: 540))
branches.curve(
    to: NSPoint(x: 686, y: 390),
    controlPoint1: NSPoint(x: 550, y: 490),
    controlPoint2: NSPoint(x: 636, y: 468)
)
stroke(branches, width: 48)

NSColor.white.setFill()
NSBezierPath(
    roundedRect: NSRect(x: 242, y: 680, width: 540, height: 64),
    xRadius: 32,
    yRadius: 32
).fill()

backgroundColor.setFill()
NSBezierPath(
    roundedRect: NSRect(x: 449, y: 665, width: 126, height: 96),
    xRadius: 30,
    yRadius: 30
).fill()

NSColor.white.setFill()
NSBezierPath(
    ovalIn: NSRect(x: 462, y: 490, width: 100, height: 100)
).fill()

let nodes: [(NSPoint, NSColor)] = [
    (
        NSPoint(x: 338, y: 344),
        NSColor(calibratedRed: 0.02, green: 0.82, blue: 0.9, alpha: 1)
    ),
    (
        NSPoint(x: 512, y: 344),
        NSColor(calibratedRed: 1, green: 0.28, blue: 0.32, alpha: 1)
    ),
    (
        NSPoint(x: 686, y: 344),
        NSColor(calibratedRed: 0.02, green: 0.82, blue: 0.9, alpha: 1)
    ),
]

for (center, color) in nodes {
    NSColor.white.setFill()
    NSBezierPath(
        ovalIn: NSRect(x: center.x - 62, y: center.y - 62, width: 124, height: 124)
    ).fill()

    color.setFill()
    NSBezierPath(
        ovalIn: NSRect(x: center.x - 32, y: center.y - 32, width: 64, height: 64)
    ).fill()
}

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:])
else {
    exit(1)
}
try png.write(to: URL(fileURLWithPath: output), options: .atomic)
