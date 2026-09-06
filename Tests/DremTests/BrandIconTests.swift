import DremBrand
import AppKit
import Testing
@testable import Drem

@MainActor
struct BrandIconTests {
    @Test func idleMenuUsesTheSingleCenteredSpark() throws {
        let idle = try #require(StatusItemController.statusImage(
            isAwake: false, activeIcon: .moon, tint: .orange
        ))
        let sparkle = try #require(StatusItemController.statusSymbolImage("sparkle", tint: nil))
        let centeredSpark = DremMark.menuImage()
        let outlineMoon = try #require(StatusItemController.statusSymbolImage("moon", tint: nil))
        let power = try #require(StatusItemController.statusSymbolImage("power", tint: nil))
        #expect(idle.isTemplate)
        #expect(idle.size == NSSize(width: 18, height: 18))
        #expect(idle.tiffRepresentation == centeredSpark.tiffRepresentation)
        #expect(idle.tiffRepresentation != sparkle.tiffRepresentation)
        #expect(idle.tiffRepresentation != outlineMoon.tiffRepresentation)
        #expect(idle.tiffRepresentation != power.tiffRepresentation)
    }

    @Test func disabledBlockerAlwaysUsesMonochromeStar() throws {
        let expected = DremMark.menuImage()
        for icon in KeepAwakeActiveIcon.allCases {
            for tint in KeepAwakeIconTint.allCases {
                let idle = try #require(StatusItemController.statusImage(
                    isAwake: false, activeIcon: icon, tint: tint
                ))
                #expect(idle.isTemplate)
                #expect(idle.size == DremMark.size)
                #expect(idle.tiffRepresentation == expected.tiffRepresentation)
            }
        }
    }

    @Test func enabledBlockerUsesSelectedIconAndColor() throws {
        for icon in KeepAwakeActiveIcon.allCases {
            for tint in KeepAwakeIconTint.allCases {
                let active = try #require(StatusItemController.statusImage(
                    isAwake: true, activeIcon: icon, tint: tint
                ))
                let color = StatusItemController.statusTint(tint)
                let expected = try #require(icon == .drem
                    ? DremMark.menuImage(tint: color)
                    : StatusItemController.statusSymbolImage(icon.systemSymbolName, tint: color))
                #expect(active.isTemplate == (tint == .none))
                #expect(active.size == expected.size)
                #expect(active.tiffRepresentation == expected.tiffRepresentation)
            }
        }
    }

    @Test func menuSymbolIsSmallerAndUsesTheReferenceBatteryTint() throws {
        let color = try #require(StatusItemController.statusTint(.orange)?.usingColorSpace(.sRGB))
        #expect(abs(color.redComponent - 248.0 / 255) < 0.0001)
        #expect(abs(color.greenComponent - 216.0 / 255) < 0.0001)
        #expect(abs(color.blueComponent - 73.0 / 255) < 0.0001)
        let moon = try #require(StatusItemController.statusSymbolImage("moon.fill", tint: color))
        let previous = try #require(NSImage(systemSymbolName: "moon.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .semibold)))
        #expect(moon.size.height < previous.size.height)
        #expect(moon.size.width < previous.size.width)
        #expect(!moon.isTemplate)
        let monochrome = try #require(StatusItemController.statusSymbolImage("moon.fill", tint: nil))
        #expect(monochrome.isTemplate)
        #expect(monochrome.size == moon.size)
        #expect(StatusItemController.statusTint(.none) == nil)
        #expect(StatusItemController.statusTint(.blue) == .systemBlue)
    }

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
