import DremCore
import Foundation
import Testing
@testable import Drem

@MainActor
struct ClosedLidBrightnessTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DREM_LIVE_DISPLAY_TESTS"] == "1"))
    func liveBuiltinDisplayReadAndSameValueWrite() throws {
        let watcher = LidStateObserver { _ in }
        defer { watcher.stop() }
        #expect(watcher.start())
        #expect(watcher.currentState != nil, "This opt-in check requires a MacBook")
        let panel = BuiltinDisplayBrightness.live
        let before = try #require(panel.read())
        #expect(panel.write(before, before.brightness), "Write the current level without dimming the open screen")
        let after = try #require(panel.read())
        #expect(after.displayUUID == before.displayUUID)
        #expect(abs(after.brightness - before.brightness) < 0.01)
    }

    private final class Panel {
        var value: Float = 0.73
        var uuid = "builtin-test-panel"
        var canRead = true
        var canWrite = true
        var writes: [Float] = []
        var willWrite: (() -> Void)?

        var access: BuiltinDisplayBrightness {
            BuiltinDisplayBrightness(
                read: { [self] in
                    canRead ? BuiltinBrightnessSnapshot(displayUUID: uuid, brightness: value) : nil
                },
                write: { [self] snapshot, target in
                    willWrite?()
                    guard canWrite, uuid == snapshot.displayUUID else { return false }
                    writes.append(target)
                    value = target
                    return true
                }
            )
        }
    }

    private func preferences() -> (UserDefaults, String) {
        let suite = "DremBrightnessTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test func closingSavesBeforeDimmingAndOpeningRestoresTheExactValue() throws {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let panel = Panel()
        let controller = ClosedLidBrightnessController(defaults: defaults, brightness: panel.access, monitorSystem: false)
        defer { controller.shutdown() }
        controller.lidStateDidChange(false)
        controller.update(agentWakeActive: true)
        #expect(panel.writes.isEmpty, "An open screen is never dimmed")
        panel.willWrite = {
            #expect(defaults.data(forKey: ClosedLidBrightnessController.recoveryKey) != nil,
                    "Persist a recovery record before the first hardware write")
        }
        controller.lidStateDidChange(true)
        #expect(panel.writes == [0])
        #expect(controller.isDimmed)
        let data = try #require(defaults.data(forKey: ClosedLidBrightnessController.recoveryKey))
        let record = try JSONDecoder().decode(BuiltinBrightnessSnapshot.self, from: data)
        #expect(record.brightness == 0.73)
        controller.lidStateDidChange(true)
        controller.update(agentWakeActive: true)
        controller.systemDidChange()
        #expect(panel.writes == [0], "Duplicate events cannot recapture zero or repeat hardware writes")
        controller.lidStateDidChange(false)
        #expect(panel.writes == [0, 0.73])
        #expect(!controller.isDimmed)
        #expect(defaults.data(forKey: ClosedLidBrightnessController.recoveryKey) == nil)
        panel.value = 0.41
        controller.lidStateDidChange(true)
        controller.lidStateDidChange(false)
        #expect(panel.writes == [0, 0.73, 0, 0.41], "Each closure captures the current user brightness")
    }

    @Test func noAgentsUnknownLidOrAlreadyDarkScreenDoesNotWriteBrightness() {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let panel = Panel()
        let controller = ClosedLidBrightnessController(defaults: defaults, brightness: panel.access, monitorSystem: false)
        defer { controller.shutdown() }
        controller.update(agentWakeActive: true)
        #expect(panel.writes.isEmpty, "Unknown lid state is not treated as closed")
        controller.update(agentWakeActive: false)
        controller.lidStateDidChange(true)
        #expect(panel.writes.isEmpty, "A closed lid alone does not request brightness changes")
        panel.value = 0
        controller.update(agentWakeActive: true)
        controller.lidStateDidChange(false)
        #expect(panel.writes.isEmpty)
        #expect(defaults.data(forKey: ClosedLidBrightnessController.recoveryKey) == nil)
    }

    @Test func taskCompletionKeepsThePanelDarkUntilOpeningButDoesNotHoldSleep() {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let panel = Panel()
        let controller = ClosedLidBrightnessController(defaults: defaults, brightness: panel.access, monitorSystem: false)
        let manager = KeepAwakeManager(
            defaults: defaults, monitorSystem: false,
            clamshellWrite: { _, completion in completion(true) }, clamshellRestoreSync: { true },
            clamshellConfigured: true, batterySnapshot: { nil }
        )
        defer { controller.shutdown(); manager.deactivate(reason: .quit) }
        controller.bind(to: manager)
        controller.lidStateDidChange(false)
        manager.recoverIfNeeded()
        manager.whileAgentsWork = true
        manager.agentActivityDidChange(hasWorkingAgent: true)
        controller.lidStateDidChange(true)
        #expect(panel.value == 0)
        manager.agentActivityDidChange(hasWorkingAgent: false)
        #expect(!manager.isActive, "Brightness ownership cannot extend the sleep-blocking session")
        #expect(panel.value == 0, "Do not light the closed panel as the final task finishes")
        controller.lidStateDidChange(false)
        #expect(panel.value == 0.73)
        #expect(!controller.isDimmed)

        manager.whileAgentsWork = false
        manager.activate(minutes: 0, trigger: .manual)
        controller.lidStateDidChange(true)
        #expect(panel.writes == [0, 0.73], "Manual wake without agent work is unaffected")
    }

    @Test func originalBrightnessSurvivesCrashAndRestoresOnOpening() {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let panel = Panel()
        var first: ClosedLidBrightnessController? = ClosedLidBrightnessController(
            defaults: defaults, brightness: panel.access, monitorSystem: false
        )
        first?.update(agentWakeActive: true)
        first?.lidStateDidChange(true)
        first = nil // Simulated crash: no graceful shutdown; no actual hardware used.
        #expect(panel.value == 0)
        let next = ClosedLidBrightnessController(defaults: defaults, brightness: panel.access, monitorSystem: false)
        defer { next.shutdown() }
        next.lidStateDidChange(true)
        #expect(panel.value == 0)
        next.lidStateDidChange(false)
        #expect(panel.value == 0.73)
        #expect(defaults.data(forKey: ClosedLidBrightnessController.recoveryKey) == nil)
    }

    @Test func quitRestoresAndLateEventsCannotDimAgain() {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let panel = Panel()
        let controller = ClosedLidBrightnessController(defaults: defaults, brightness: panel.access, monitorSystem: false)
        controller.update(agentWakeActive: true)
        controller.lidStateDidChange(true)
        controller.shutdown()
        #expect(panel.value == 0.73)
        controller.lidStateDidChange(false)
        controller.lidStateDidChange(true)
        controller.update(agentWakeActive: true)
        controller.systemDidChange()
        #expect(panel.writes == [0, 0.73])
    }

    @Test func unavailableReadNeverDimsAndFailedRestoreKeepsRecovery() {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let panel = Panel()
        panel.canRead = false
        let controller = ClosedLidBrightnessController(defaults: defaults, brightness: panel.access, monitorSystem: false)
        defer { controller.shutdown() }
        controller.update(agentWakeActive: true)
        controller.lidStateDidChange(true)
        #expect(panel.writes.isEmpty)
        #expect(controller.lastError != nil)
        panel.canRead = true
        controller.systemDidChange()
        #expect(panel.value == 0)
        panel.canWrite = false
        controller.lidStateDidChange(false)
        #expect(defaults.data(forKey: ClosedLidBrightnessController.recoveryKey) != nil)
        #expect(controller.isDimmed)
        panel.canWrite = true
        controller.systemDidChange()
        #expect(panel.value == 0.73)
        #expect(controller.lastError == nil)
    }

    @Test func displayChangesNeverRestoreOntoADifferentPanel() {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let panel = Panel()
        let controller = ClosedLidBrightnessController(defaults: defaults, brightness: panel.access, monitorSystem: false)
        defer { controller.shutdown() }
        controller.update(agentWakeActive: true)
        controller.lidStateDidChange(true)
        panel.uuid = "different-panel"
        controller.lidStateDidChange(false)
        #expect(panel.writes == [0])
        #expect(defaults.data(forKey: ClosedLidBrightnessController.recoveryKey) != nil)
        panel.uuid = "builtin-test-panel"
        controller.systemDidChange()
        #expect(panel.writes == [0, 0.73])
    }

    @Test func displayReconfigurationRedimsWithoutReplacingOriginalBrightness() {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let panel = Panel()
        let controller = ClosedLidBrightnessController(defaults: defaults, brightness: panel.access, monitorSystem: false)
        defer { controller.shutdown() }
        controller.update(agentWakeActive: true)
        controller.lidStateDidChange(true)
        panel.value = 0.2
        controller.systemDidChange()
        #expect(panel.writes == [0, 0])
        controller.lidStateDidChange(false)
        #expect(panel.writes == [0, 0, 0.73])
    }
}
