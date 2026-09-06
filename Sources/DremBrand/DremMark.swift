import AppKit

/// One centered, static spark: a system-tinted template or a chosen solid color.
public enum DremMark {
    public static let size = NSSize(width: 18, height: 18)
    public static let batteryYellow = NSColor(srgbRed: 248 / 255, green: 216 / 255, blue: 73 / 255, alpha: 1)

    public static func menuImage(tint: NSColor? = nil) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            draw(in: rect, color: tint ?? .black)
            return true
        }
        image.isTemplate = tint == nil
        image.accessibilityDescription = "drem"
        return image
    }

    public static func draw(in rect: NSRect, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scaleX(by: rect.width / 20, yBy: rect.height / 20)
        transform.concat()
        color.setFill()
        spark(center: NSPoint(x: 10, y: 10), radiusX: 6.3, radiusY: 7.4, tilt: -9).fill()
    }

    private static func spark(center: NSPoint, radiusX x: CGFloat, radiusY y: CGFloat,
                              tilt: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: y))
        path.curve(to: NSPoint(x: x, y: 0),
                   controlPoint1: NSPoint(x: x * 0.16, y: y * 0.24),
                   controlPoint2: NSPoint(x: x * 0.24, y: y * 0.16))
        path.curve(to: NSPoint(x: 0, y: -y),
                   controlPoint1: NSPoint(x: x * 0.24, y: -y * 0.16),
                   controlPoint2: NSPoint(x: x * 0.16, y: -y * 0.24))
        path.curve(to: NSPoint(x: -x, y: 0),
                   controlPoint1: NSPoint(x: -x * 0.16, y: -y * 0.24),
                   controlPoint2: NSPoint(x: -x * 0.24, y: -y * 0.16))
        path.curve(to: NSPoint(x: 0, y: y),
                   controlPoint1: NSPoint(x: -x * 0.24, y: y * 0.16),
                   controlPoint2: NSPoint(x: -x * 0.16, y: y * 0.24))
        path.close()
        var transform = AffineTransform(translationByX: center.x, byY: center.y)
        transform.rotate(byDegrees: tilt)
        path.transform(using: transform)
        return path
    }
}
