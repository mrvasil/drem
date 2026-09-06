import AppKit

// Build-time only. The same vector master is drawn directly for the menu bar.
@main
enum IconRenderer {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fatalError("Usage: icon-renderer <resource-directory>")
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let iconset = directory.appendingPathComponent("Drem.iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
                try png(size: points * scale, appIcon: true).write(to: iconset.appendingPathComponent(name))
            }
        }
        try png(size: 1024, appIcon: true).write(to: directory.appendingPathComponent("AppIcon.png"))
        try png(size: 1024, appIcon: false).write(to: directory.appendingPathComponent("DremLogo.png"))
    }

    private static func png(size: Int, appIcon: Bool) throws -> Data {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw CocoaError(.fileWriteUnknown)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
        if appIcon {
            let tile = superellipse(in: NSRect(x: 92, y: 92, width: 840, height: 840))
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
            shadow.shadowOffset = NSSize(width: 0, height: -12)
            shadow.shadowBlurRadius = 20
            shadow.set()
            NSColor(srgbRed: 0.13, green: 0.14, blue: 0.16, alpha: 1).setFill()
            tile.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGradient(starting: NSColor(srgbRed: 0.09, green: 0.10, blue: 0.12, alpha: 1),
                       ending: NSColor(srgbRed: 0.22, green: 0.23, blue: 0.25, alpha: 1))?
                .draw(in: tile, angle: 90)
            NSColor.white.withAlphaComponent(0.12).setStroke()
            tile.lineWidth = 3
            tile.stroke()
            DremMark.draw(in: NSRect(x: 160, y: 160, width: 704, height: 704), color: DremMark.batteryYellow)
        } else {
            DremMark.draw(in: NSRect(x: 32, y: 32, width: 960, height: 960), color: DremMark.batteryYellow)
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    private static func superellipse(in rect: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        for step in 0...256 {
            let angle = Double(step) / 256 * .pi * 2
            let x = cos(angle), y = sin(angle)
            let point = NSPoint(
                x: rect.midX + rect.width / 2 * copysign(pow(abs(x), 2 / 4.5), x),
                y: rect.midY + rect.height / 2 * copysign(pow(abs(y), 2 / 4.5), y)
            )
            if step == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        path.close()
        return path
    }
}
