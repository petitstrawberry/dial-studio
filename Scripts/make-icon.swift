import AppKit
let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: px, height: px)
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let rect = NSRect(x: 0, y: 0, width: px, height: px)
        let inset = Double(px) * 0.07
        NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: Double(px) * 0.21, yRadius: Double(px) * 0.21).fill()
        let unit = CGFloat(px), center = CGPoint(x: unit * 0.5, y: unit * 0.5)
        NSColor(calibratedWhite: 0.28, alpha: 1).setFill()
        let radius = unit * 0.155
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
        let dotRadius = unit * 0.021
        for degrees in [90.0, 45, 0, -45, -135, 180, 135] {
            let angle = degrees * .pi / 180
            let x = center.x + unit * 0.24 * cos(angle)
            let y = center.y + unit * 0.24 * sin(angle)
            NSBezierPath(ovalIn: NSRect(x: x - dotRadius, y: y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)).fill()
        }
        NSColor(calibratedWhite: 0.94, alpha: 1).setStroke()
        let marker = NSBezierPath()
        marker.lineWidth = unit * 0.035; marker.lineCapStyle = .round
        marker.move(to: center)
        marker.line(to: CGPoint(x: center.x + unit * 0.12, y: center.y - unit * 0.12))
        marker.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination).appendingPathComponent(filename))
    }
}
