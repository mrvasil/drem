import AppKit

/// Read only on environment events or an explicit Show command, never polled.
/// Notifications are invalidations, not an indefinitely cached OS state.
struct IslandEnvironmentSnapshot: Equatable {
    struct Placement: Equatable {
        var frame: CGRect
        var centerX: CGFloat
        var notchWidth: CGFloat
        var notchHeight: CGFloat
    }

    var placement: Placement?
    var displayAsleep: Bool
    var sessionActive: Bool
    var locked: Bool
    var lidClosed: Bool?

    var blockedReason: String? {
        if locked { return "locked" }
        if !sessionActive { return "inactive-session" }
        if lidClosed != false { return lidClosed == true ? "closed-lid" : "unknown-lid" }
        if placement == nil { return "no-notched-display" }
        if displayAsleep { return "display-asleep" }
        return nil
    }

    @MainActor
    static func read(lidClosed: Bool?) -> Self {
        let screen = IslandController.notchedScreen()
        var placement: Placement?
        if let screen, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            placement = Placement(frame: screen.frame, centerX: (left.maxX + right.minX) / 2,
                notchWidth: right.minX - left.maxX, notchHeight: screen.safeAreaInsets.top)
        }
        let id = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return Self(placement: placement, displayAsleep: id.map { CGDisplayIsAsleep($0) != 0 } ?? true,
            sessionActive: session?["kCGSSessionOnConsoleKey"] as? Bool == true,
            locked: session == nil || (session?["CGSSessionScreenIsLocked"] as? Bool ?? false),
            lidClosed: lidClosed)
    }
}
