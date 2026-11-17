import CoreGraphics
import Foundation

/// One captured finger gesture, independent of monitor replacement or animation.
/// Only release commits; momentum and gestures begun outside the header never do.
struct IslandSwipe {
    enum Intent: Equatable { case hide, restore }
    enum Phase { case none, began, changed, ended, cancelled }
    enum Resolution: Equatable { case commit(Intent), cancel }
    enum Axis { case horizontal, vertical }

    struct Feedback: Equatable {
        let intent: Intent
        let horizontal: CGFloat
        let vertical: CGFloat // Positive = fingers upward.
        let distance: CGFloat
        var progress: CGFloat { min(1, max(0, distance / 44)) }
        var ready: Bool { distance >= 44 }

        var offsetX: CGFloat { 13 * tanh(horizontal / 65) }
        var offsetY: CGFloat {
            intent == .hide ? -min(10, max(0, vertical) * 0.16) : -7 * (1 - progress)
        }
        var scaleX: CGFloat { intent == .hide ? 1 - progress * 0.10 : 0.72 + progress * 0.28 }
        var scaleY: CGFloat { intent == .hide ? 1 - progress * 0.22 : 0.78 + progress * 0.22 }
        var opacity: CGFloat { intent == .hide ? 1 - progress * 0.35 : 0.12 + progress * 0.88 }
    }

    struct Update {
        var captured = false
        var feedback: Feedback?
        var resolution: Resolution?
        var thresholdCrossed = false
    }

    private var horizontal: CGFloat = 0
    private var vertical: CGFloat = 0
    private var lastEvent: TimeInterval = 0
    private var velocity: CGFloat = 0
    private var tracking = false
    private var ticked = false
    private var axis: Axis?
    private var intent: Intent?
    private(set) var feedback: Feedback?

    mutating func reset() { self = IslandSwipe() }

    mutating func consume(x: CGFloat, y: CGFloat, inverted: Bool, precise: Bool,
                          timestamp: TimeInterval, phase: Phase, momentum: Bool,
                          intent candidate: Intent?) -> Update {
        guard precise, !momentum else { return Update() }
        if phase == .ended || phase == .cancelled {
            return finish(at: timestamp, cancelled: phase == .cancelled)
        }
        let starts = phase == .began || (phase == .none && (!tracking || timestamp - lastEvent > 0.35))
        if starts {
            reset()
            tracking = true
            intent = candidate
            lastEvent = timestamp
        }
        // Eligibility is captured once. Moving off the header must not hand an
        // already-captured scroll to content, or capture an unrelated scroll.
        guard tracking, let intent else { return Update() }
        let oldDistance = directedDistance(intent)
        horizontal += inverted ? -x : x
        vertical += inverted ? -y : y
        if axis == nil, max(abs(horizontal), abs(vertical)) >= 5 {
            if abs(horizontal) > abs(vertical) * 1.2 { axis = .horizontal }
            else if abs(vertical) > abs(horizontal) * 1.2 { axis = .vertical }
        }
        let distance = directedDistance(intent)
        let interval = timestamp - lastEvent
        if interval > 0, interval < 0.15, x != 0 || y != 0 {
            velocity = velocity * 0.3 + ((distance - oldDistance) / interval) * 0.7
        } else if interval >= 0.15 { velocity = 0 }
        lastEvent = timestamp
        let next = Feedback(intent: intent, horizontal: horizontal, vertical: vertical, distance: distance)
        let crossed = next.ready && !ticked
        ticked = ticked || next.ready
        feedback = next
        return Update(captured: true, feedback: next, thresholdCrossed: crossed)
    }

    mutating func finish(at timestamp: TimeInterval, cancelled: Bool = false) -> Update {
        guard tracking, let intent else { reset(); return Update() }
        let distance = directedDistance(intent)
        let projected = distance + (timestamp - lastEvent < 0.1 ? max(0, velocity) * 0.08 : 0)
        let commit = !cancelled && (distance >= 44 || (distance >= 18 && projected >= 44))
        tracking = false
        feedback = nil
        return Update(captured: true, resolution: commit ? .commit(intent) : .cancel)
    }

    private func directedDistance(_ intent: Intent) -> CGFloat {
        switch axis {
        case .horizontal: return abs(horizontal)
        case .vertical: return max(0, intent == .hide ? vertical : -vertical)
        case nil: return 0
        }
    }
}
