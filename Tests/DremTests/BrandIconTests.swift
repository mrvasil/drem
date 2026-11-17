import DremBrand
import AppKit
import Testing
@testable import Drem

@MainActor
struct BrandIconTests {
    @Test(arguments: [1, 2, 3], [false, true])
    func singleSparkHasNoSatelliteAndIsUnclippedAtEveryScale(scale: Int, tinted: Bool) throws {
        let side = 18 * scale
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        DremMark.menuImage(tint: tinted ? DremMark.batteryYellow : nil)
            .draw(in: NSRect(origin: .zero, size: DremMark.size))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        var pixels = (0..<(side * side)).map { index in
            (bitmap.colorAt(x: index % side, y: index / side)?.alphaComponent ?? 0) > 0.2
        }
        for edge in 0..<side {
            #expect(!pixels[edge] && !pixels[(side - 1) * side + edge])
            #expect(!pixels[edge * side] && !pixels[edge * side + side - 1])
        }
        if tinted {
            let center = try #require(bitmap.colorAt(x: side / 2, y: side / 2)?.usingColorSpace(.sRGB))
            #expect(center.alphaComponent > 0.99)
            #expect(center.redComponent > 0.9 && center.greenComponent > 0.7 && center.blueComponent < 0.4)
        }
        // One connected, filled star: no satellite or detached specks.
        var components: [Int] = []
        while let seed = pixels.firstIndex(of: true) {
            var pending = [seed]
            var count = 0
            pixels[seed] = false
            while let point = pending.popLast() {
                count += 1
                for dy in -1...1 {
                    for dx in -1...1 {
                        let x = point % side + dx, y = point / side + dy
                        guard x >= 0, x < side, y >= 0, y < side else { continue }
                        let neighbor = y * side + x
                        if pixels[neighbor] { pixels[neighbor] = false; pending.append(neighbor) }
                    }
                }
            }
            components.append(count)
        }
        #expect(components.count == 1)
        #expect((components.first ?? 0) > 15 * scale * scale)
    }

    @Test func menuMarkIsResolutionIndependentAndFollowsSystemAppearance() throws {
        let idle = DremMark.menuImage()
        let tinted = DremMark.menuImage(tint: .systemPink)
        #expect(idle.isTemplate)
        #expect(!tinted.isTemplate)
        #expect(idle.size == NSSize(width: 18, height: 18))
        let activeData = try #require(tinted.tiffRepresentation)
        let idleData = try #require(idle.tiffRepresentation)
        #expect(activeData != idleData)
        #expect(activeData.count > 100)
    }
}
