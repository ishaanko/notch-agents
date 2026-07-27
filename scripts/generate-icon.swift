import AppKit

let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

let background = NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928), xRadius: 220, yRadius: 220)
NSColor(calibratedRed: 0.018, green: 0.022, blue: 0.035, alpha: 1).setFill()
background.fill()

let inner = NSBezierPath(roundedRect: NSRect(x: 82, y: 82, width: 860, height: 860), xRadius: 190, yRadius: 190)
NSColor(calibratedRed: 0.035, green: 0.045, blue: 0.07, alpha: 1).setFill()
inner.fill()

let center = NSPoint(x: 512, y: 512)
let shadow = NSShadow()
shadow.shadowColor = NSColor(calibratedRed: 0.16, green: 0.72, blue: 1, alpha: 0.92)
shadow.shadowBlurRadius = 48
shadow.shadowOffset = .zero
let rotations = [-58.0, 0.0, 58.0]
let phases = [0.4, 2.3, 4.5]
for orbitIndex in rotations.indices {
    let rotation = rotations[orbitIndex] * .pi / 180
    for ghostIndex in 0..<18 {
        let angle = Double(ghostIndex) / 18 * 2 * .pi
        let localX = 300 * cos(angle)
        let localY = 126 * sin(angle)
        let x = center.x + CGFloat(localX * cos(rotation) - localY * sin(rotation))
        let y = center.y + CGFloat(localX * sin(rotation) + localY * cos(rotation))
        let depth = (sin(angle) + 1) / 2
        let diameter = CGFloat(17 + depth * 18)
        NSColor(calibratedWhite: 1, alpha: 0.18 + depth * 0.34).setFill()
        NSBezierPath(
            ovalIn: NSRect(
                x: x - diameter / 2,
                y: y - diameter / 2,
                width: diameter,
                height: diameter
            )
        ).fill()
    }

    for particleIndex in 0..<2 {
        let angle = phases[orbitIndex] + Double(particleIndex) * .pi
        let localX = 300 * cos(angle)
        let localY = 126 * sin(angle)
        let x = center.x + CGFloat(localX * cos(rotation) - localY * sin(rotation))
        let y = center.y + CGFloat(localX * sin(rotation) + localY * cos(rotation))
        let diameter: CGFloat = 62

        NSGraphicsContext.current?.saveGraphicsState()
        shadow.set()
        NSColor(
            calibratedRed: particleIndex == 0 ? 0.22 : 0.58,
            green: particleIndex == 0 ? 0.78 : 0.88,
            blue: 1,
            alpha: particleIndex == 0 ? 1 : 0.82
        ).setFill()
        NSBezierPath(
            ovalIn: NSRect(
                x: x - diameter / 2,
                y: y - diameter / 2,
                width: diameter,
                height: diameter
            )
        ).fill()
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: output), options: .atomic)
