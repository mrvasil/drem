import AppKit
import DremCore
import SwiftUI
import Testing
@testable import Drem

@MainActor @Suite(.serialized)
struct IslandGestureRenderTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DREM_ISLAND_GESTURE_DIRECTORY"] != nil))
    func renderFingerFollowingAndSettlement() async throws {
        let destination = try #require(ProcessInfo.processInfo.environment["DREM_ISLAND_GESTURE_DIRECTORY"])
        let model = IslandPresentation()
        model.isPresented = true
        model.rows = [IslandRow(id: "demo", kind: .claude, project: "drem", action: "Работает", status: nil, attention: .question)]
        model.lifecycle.configure(enabled: true, available: true)
        model.lifecycle.activityChanged(count: 1)
        model.sleep = IslandSleepState(active: true, clamshell: true, agentMode: true)
        let size = NSSize(width: model.expandedWidth + 40, height: model.canvasHeight + 24)
        let host = NSHostingView(rootView: IslandView(model: model, toggle: {}, hide: {}))
        let window = NSPanel(contentRect: NSRect(origin: CGPoint(x: -3000, y: -3000), size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        var captures: [(String, Data)] = []
        for frame in 0..<48 {
            // A short hide drag springs back; a restore preview follows the
            // opposite gesture. These are model traces, NOT hardware gestures.
            if frame < 12 {
                model.gesture = .init(intent: .hide, horizontal: CGFloat(frame) * 2, vertical: 0, distance: CGFloat(frame) * 2)
            } else if frame == 12 || frame == 36 {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) { model.gesture = nil }
            } else if (24..<36).contains(frame) {
                let distance = CGFloat(frame - 24) * 4
                model.gesture = .init(intent: .restore, horizontal: -distance, vertical: 0, distance: distance)
            }
            try await Task.sleep(for: .milliseconds(33))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            captures.append((String(format: "gesture-%03d.png", frame),
                try #require(bitmap.representation(using: .png, properties: [:]))))
        }
        for (name, data) in captures {
            try data.write(to: URL(fileURLWithPath: destination).appendingPathComponent(name))
        }
    }
}
