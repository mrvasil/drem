import DremCore
import Foundation
import Testing
@testable import Drem

@Suite(.serialized)
@MainActor
struct MouseJiggleLifecycleTests {
    private func timer(in manager: KeepAwakeManager) -> Timer? {
        Mirror(reflecting: manager).children.first { $0.label == "mouseJiggleTimer" }?.value as? Timer
    }

    @Test
    func manualPointerTimerIsCancelledWhenAgentModeTakesOver() {
        let suite = "DremTests.MouseJiggle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: KeepAwakeDefaultsKey.mouseJiggleEnabled)
        let manager = KeepAwakeManager(
            defaults: defaults, monitorSystem: false,
            clamshellWrite: { _, completion in completion(true) },
            clamshellRestoreSync: { true }, clamshellConfigured: true,
            batterySnapshot: { nil }
        )
        defer { manager.deactivate(reason: .quit) }
        manager.recoverIfNeeded()
        manager.activate(minutes: 0, trigger: .manual)
        let manualTimer = timer(in: manager)
        #expect(manualTimer?.isValid == true)
        manager.agentActivityDidChange(hasWorkingAgent: true)
        manager.whileAgentsWork = true
        #expect(manager.isActive)
        #expect(manager.sessionTrigger == .automation)
        #expect(manualTimer?.isValid == false)
        #expect(timer(in: manager) == nil)
        manager.syncWithPreferences()
        #expect(timer(in: manager) == nil, "Working-agent refresh must not recreate pointer activity")
        #expect(defaults.bool(forKey: KeepAwakeDefaultsKey.mouseJiggleEnabled),
                "The independent manual preference is retained")
    }
    private final class Pointer {
        var location = CGPoint(x: 20, y: 20)
        var moves: [CGPoint] = []

        var control: KeepAwakeManager.PointerControl {
            .init(
                location: { self.location },
                target: { CGPoint(x: $0.x + 1, y: $0.y) },
                move: { self.moves.append($0); self.location = $0; return true }
            )
        }
    }

    private func stopPointerActivity(_ manager: KeepAwakeManager, transition: String) {
        switch transition {
        case "agent": manager.whileAgentsWork = true
        case "pause": manager.screenLockStateDidChange(locked: true)
        case "deactivate": manager.deactivate(reason: .manual)
        case "restart":
            manager.deactivate(reason: .manual)
            manager.activate(minutes: 0, trigger: .manual)
        default: manager.deactivate(reason: .quit)
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(1)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(condition())
    }

    @Test(arguments: ["agent", "pause", "deactivate", "quit", "restart"])
    func queuedTimerCannotMovePointerAfterLifecycleChange(transition: String) async throws {
        let suite = "DremTests.MouseJiggle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: KeepAwakeDefaultsKey.mouseJiggleEnabled)
        defaults.set(true, forKey: KeepAwakeDefaultsKey.pauseWhenLocked)
        let pointer = Pointer()
        let manager = KeepAwakeManager(
            defaults: defaults, monitorSystem: false,
            clamshellWrite: { _, completion in completion(true) },
            clamshellRestoreSync: { true }, clamshellConfigured: true,
            pointerControl: pointer.control, batterySnapshot: { nil }
        )
        defer { manager.deactivate(reason: .quit) }
        manager.recoverIfNeeded()
        manager.activate(minutes: 0, trigger: .manual)
        manager.agentActivityDidChange(hasWorkingAgent: true)
        timer(in: manager)?.fire()
        // Timer delivery has queued a MainActor task, but it has not run yet.
        stopPointerActivity(manager, transition: transition)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(pointer.moves.isEmpty)
        #expect(defaults.bool(forKey: KeepAwakeDefaultsKey.mouseJiggleEnabled))
    }

    @Test(arguments: ["agent", "pause", "deactivate", "quit", "restart"])
    func pendingReturnCannotMovePointerAfterLifecycleChange(transition: String) async throws {
        let suite = "DremTests.MouseJiggle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: KeepAwakeDefaultsKey.mouseJiggleEnabled)
        defaults.set(true, forKey: KeepAwakeDefaultsKey.pauseWhenLocked)
        let pointer = Pointer()
        let manager = KeepAwakeManager(
            defaults: defaults, monitorSystem: false,
            clamshellWrite: { _, completion in completion(true) },
            clamshellRestoreSync: { true }, clamshellConfigured: true,
            pointerControl: pointer.control, batterySnapshot: { nil }
        )
        defer { manager.deactivate(reason: .quit) }
        manager.recoverIfNeeded()
        manager.activate(minutes: 0, trigger: .manual)
        manager.agentActivityDidChange(hasWorkingAgent: true)
        timer(in: manager)?.fire()
        try await waitUntil { pointer.moves.count == 1 }
        stopPointerActivity(manager, transition: transition)
        // The production return delay is 80ms. Observe beyond that deadline.
        try await Task.sleep(nanoseconds: 120_000_000)
        #expect(pointer.moves == [CGPoint(x: 21, y: 20)])
        #expect(defaults.bool(forKey: KeepAwakeDefaultsKey.mouseJiggleEnabled))
    }

    @Test
    func manualPointerMovementStillReturnsToItsOriginalPosition() async throws {
        let suite = "DremTests.MouseJiggle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: KeepAwakeDefaultsKey.mouseJiggleEnabled)
        let pointer = Pointer()
        let manager = KeepAwakeManager(
            defaults: defaults, monitorSystem: false,
            clamshellRestoreSync: { true }, clamshellConfigured: true,
            pointerControl: pointer.control, batterySnapshot: { nil }
        )
        defer { manager.deactivate(reason: .quit) }
        manager.recoverIfNeeded()
        manager.activate(minutes: 0, trigger: .manual)
        timer(in: manager)?.fire()
        try await waitUntil { pointer.moves.count == 2 }
        #expect(pointer.moves == [CGPoint(x: 21, y: 20), CGPoint(x: 20, y: 20)])
    }

}
