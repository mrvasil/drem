import AppKit

/// Build-time visual check of the same vector mark used by the status item.
@main
enum PreviewDremMark {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fatalError("Usage: preview-drem-mark <output.png>")
        }
        let width = 280, height = 150, scale = 2
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width * scale, pixelsHigh: height * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw CocoaError(.fileWriteUnknown)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        for dark in [false, true] {
            let y: CGFloat = dark ? 0 : 75
            let foreground: NSColor = dark ? .white : .black
            (dark ? NSColor.black : NSColor(white: 0.95, alpha: 1)).setFill()
            NSRect(x: 0, y: y, width: CGFloat(width), height: 75).fill()
            for (text, x) in [("Выключен", CGFloat(20)), ("Включён", CGFloat(108))] {
                (text as NSString).draw(at: NSPoint(x: x, y: y + 48), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: foreground
                ])
            }
            DremMark.draw(in: NSRect(x: 28, y: y + 19, width: 18, height: 18), color: foreground)
            DremMark.draw(in: NSRect(x: 124, y: y + 19, width: 18, height: 18), color: DremMark.batteryYellow)
            DremMark.draw(in: NSRect(x: 202, y: y + 10, width: 54, height: 54), color: DremMark.batteryYellow)
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
