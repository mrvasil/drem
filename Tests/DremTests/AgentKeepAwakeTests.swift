import DremCore
import Foundation
import Testing
@testable import Drem

@Suite(.serialized)
@MainActor
struct AgentKeepAwakeTests {
    private final class LidWrites {
        var values: [Bool] = []
        var pending: [(Bool) -> Void] = []

        func write(_ value: Bool, completion: @escaping (Bool) -> Void) {
            values.append(value)
            pending.append(completion)
        }

        func finish() async {
            guard !pending.isEmpty else {
                Issue.record("Expected a pending system write")
                return
            }
            pending.removeFirst()(true)
            // Drain the manager's main-queue completion, without sleeping.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private func preferences() -> (UserDefaults, String) {
        let name = "DremTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test
    func testAgentLifecycleAndDisableSwitch() async {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(30, forKey: KeepAwakeDefaultsKey.defaultDuration)
        let writes = LidWrites()
        let manager = KeepAwakeManager(
            defaults: defaults, monitorSystem: false, clamshellWrite: writes.write,
            clamshellConfigured: true, batterySnapshot: { nil }
        )
        manager.recoverIfNeeded()
        manager.agentActivityDidChange(hasWorkingAgent: true)
        #expect(!manager.isActive, "Working agents alone do not enable the opt-in")
        manager.whileAgentsWork = true
        #expect(manager.isActive)
        #expect(manager.sessionTrigger == .automation)
        #expect(manager.activeAutomationConditions == [.agents])
        #expect(manager.endDate == nil, "Agent sessions must outlive the manual default duration")
        #expect(writes.values == [true])
        #expect(defaults.bool(forKey: KeepAwakeDefaultsKey.sleepDisabledFlag))
        await writes.finish()
        #expect(manager.clamshellActive)

        manager.agentActivityDidChange(hasWorkingAgent: true)
        #expect(writes.values == [true], "Repeated working snapshots cost no system writes")
        manager.agentActivityDidChange(hasWorkingAgent: false)
        #expect(!manager.isActive)
        #expect(writes.values == [true, false])
        await writes.finish()
        #expect(!manager.clamshellActive)
        #expect(!defaults.bool(forKey: KeepAwakeDefaultsKey.sleepDisabledFlag))
        #expect(manager.whileAgentsWork, "The switch stays armed for the next task")

        manager.agentActivityDidChange(hasWorkingAgent: true)
        await writes.finish()
        manager.whileAgentsWork = false
        #expect(!manager.isActive)
        await writes.finish()
        #expect(!manager.clamshellActive)
        #expect(!defaults.bool(forKey: KeepAwakeDefaultsKey.whileAgentsWork))
        #expect(!manager.clamshellPreferred, "The independent manual lid preference was not changed")
    }

    @Test
    func testTaskFinishesWhileLidEnableIsPending() async {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let writes = LidWrites()
        let manager = KeepAwakeManager(
            defaults: defaults, monitorSystem: false, clamshellWrite: writes.write,
            clamshellConfigured: true, batterySnapshot: { nil }
        )
        manager.whileAgentsWork = true
        manager.recoverIfNeeded()
        manager.agentActivityDidChange(hasWorkingAgent: true)
        manager.agentActivityDidChange(hasWorkingAgent: false)
        #expect(!manager.isActive)
        #expect(writes.values == [true])
        await writes.finish()
        #expect(writes.values == [true, false], "A late enable is immediately restored")
        await writes.finish()
        #expect(!manager.clamshellActive)
        #expect(!defaults.bool(forKey: KeepAwakeDefaultsKey.sleepDisabledFlag))
    }

    @Test
    func testManualSessionWorksWhenAgentModeIsOff() async {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let writes = LidWrites()
        let manager = KeepAwakeManager(
            defaults: defaults, monitorSystem: false, clamshellWrite: writes.write,
            clamshellConfigured: true, batterySnapshot: { nil }
        )
        manager.recoverIfNeeded()
        manager.activate(minutes: 15, trigger: .manual)
        let manualEnd = manager.endDate
        manager.agentActivityDidChange(hasWorkingAgent: true)
        manager.agentActivityDidChange(hasWorkingAgent: false)
        #expect(manager.isActive)
        #expect(manager.sessionTrigger == .manual)
        #expect(manager.endDate == manualEnd)
        #expect(!manager.clamshellActive)

        manager.clamshellPreferred = true
        await writes.finish()
        manager.agentActivityDidChange(hasWorkingAgent: true)
        manager.agentActivityDidChange(hasWorkingAgent: false)
        #expect(manager.clamshellActive, "Explicit manual lid demand stays enabled")
        #expect(writes.pending.isEmpty)
        manager.deactivate(reason: .manual)
        await writes.finish()
    }

    @Test(arguments: [0, 15])
    func testAgentModeTakesOverAnExistingManualSession(minutes: Int) async {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: KeepAwakeDefaultsKey.clamshellPreferred)
        let writes = LidWrites()
        let manager = KeepAwakeManager(
            defaults: defaults, monitorSystem: false, clamshellWrite: writes.write,
            clamshellConfigured: true, batterySnapshot: { nil }
        )
        manager.recoverIfNeeded()
        manager.activate(minutes: minutes, trigger: .manual)
        await writes.finish()
        manager.agentActivityDidChange(hasWorkingAgent: true)
        manager.whileAgentsWork = true
        #expect(manager.sessionTrigger == .automation)
        #expect(manager.endDate == nil, "The old manual timer no longer controls agent work")
        #expect(manager.activeAutomationConditions == [.agents])
        #expect(writes.values == [true], "Taking ownership must not briefly drop lid protection")

        manager.agentActivityDidChange(hasWorkingAgent: false)
        #expect(!manager.isActive, "The final task releases even an earlier indefinite manual session")
        #expect(manager.sessionTrigger == nil)
        #expect(manager.endDate == nil)
        #expect(writes.values == [true, false])
        // Always clean up real IOKit assertions, including on the expected red run.
        if manager.isActive { manager.deactivate(reason: .manual) }
        await writes.finish()
        #expect(!manager.clamshellActive)
        #expect(!defaults.bool(forKey: KeepAwakeDefaultsKey.sleepDisabledFlag))
        #expect(manager.clamshellPreferred, "Stored manual preferences are preserved, not applied while idle")
        #expect(manager.whileAgentsWork)
    }

    @Test
    func testIdleAgentModeStopsManualAndRejectsManualEntryPoints() async {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: KeepAwakeDefaultsKey.autoStart)
        defaults.set(true, forKey: KeepAwakeDefaultsKey.clamshellPreferred)
        let writes = LidWrites()
        let manager = KeepAwakeManager(
            defaults: defaults, monitorSystem: false, clamshellWrite: writes.write,
            clamshellConfigured: true, batterySnapshot: { nil }
        )
        manager.recoverIfNeeded()
        manager.activate(minutes: 0, trigger: .manual)
        await writes.finish()
        manager.whileAgentsWork = true
        #expect(!manager.isActive)
        await writes.finish()

        manager.activateOnLaunchIfNeeded()
        manager.activate(minutes: 15)
        manager.toggle()
        manager.syncWithPreferences()
        #expect(!manager.isActive, "Launch, menu and hotkey cannot bypass idle agent mode")
        #expect(manager.endDate == nil)
        #expect(writes.values == [true, false])

        manager.agentActivityDidChange(hasWorkingAgent: true)
        await writes.finish()
        manager.activate(minutes: 15)
        manager.extend(minutes: 15)
        #expect(manager.sessionTrigger == .automation)
        #expect(manager.endDate == nil)
        manager.toggle()
        await writes.finish()
        manager.toggle()
        await writes.finish()
        #expect(manager.isActive, "Manual resume while working still belongs to the agent")
        #expect(manager.sessionTrigger == .automation)
        manager.agentActivityDidChange(hasWorkingAgent: false)
        #expect(!manager.isActive)
        await writes.finish()
        manager.whileAgentsWork = false
        #expect(!manager.isActive, "Disabling the mode must not resurrect an old manual session")
    }

    @Test
    func testLaunchWithPersistedAgentModeDoesNotStartAnIdleManualSession() {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: KeepAwakeDefaultsKey.autoStart)
        defaults.set(true, forKey: KeepAwakeDefaultsKey.whileAgentsWork)
        let writes = LidWrites()
        let manager = KeepAwakeManager(
            defaults: defaults, monitorSystem: false, clamshellWrite: writes.write,
            clamshellConfigured: true, batterySnapshot: { nil }
        )
        manager.recoverIfNeeded { manager.activateOnLaunchIfNeeded() }
        #expect(!manager.isActive)
        #expect(manager.sessionTrigger == nil)
        #expect(writes.values.isEmpty)
    }

    @Test
    func testAgentModeOverridesPowerAutomationUntilDisabled() async {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: KeepAwakeDefaultsKey.connectedToPower)
        let writes = LidWrites()
        let manager = KeepAwakeManager(
            defaults: defaults, monitorSystem: false, clamshellWrite: writes.write,
            clamshellConfigured: true,
            batterySnapshot: { KeepAwakeBatteryInfo(percent: 80, isCharging: true, isOnBattery: false) }
        )
        manager.recoverIfNeeded()
        #expect(manager.activeAutomationConditions == [.power])
        manager.whileAgentsWork = true
        #expect(!manager.isActive, "An idle agent mode also stops pre-existing power automation")
        manager.agentActivityDidChange(hasWorkingAgent: true)
        await writes.finish()
        #expect(manager.activeAutomationConditions == [.agents])
        manager.agentActivityDidChange(hasWorkingAgent: false)
        #expect(!manager.isActive, "Connected power must not override final agent completion")
        await writes.finish()
        manager.syncWithPreferences()
        #expect(!manager.isActive, "Unrelated preferences cannot resurrect the session")
        manager.whileAgentsWork = false
        #expect(manager.isActive, "The stored power preference works again outside agent mode")
        #expect(manager.activeAutomationConditions == [.power])
        manager.deactivate(reason: .manual)
    }

    @Test(arguments: [false, true])
    func testAgentModeExcludesOtherAutomationConditions(working: Bool) {
        let matches = KeepAwakeAutomationSupport.matchingConditions(
            externalDisplayEnabled: true, externalDisplayConnected: true,
            powerEnabled: true, connectedToPower: true,
            agentsEnabled: true, hasWorkingAgent: working
        )
        #expect(matches == (working ? [.agents] : []))
    }

    @Test
    func testLockDoesNotInterruptAgentAndBatteryProtectionStillStopsIt() async {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: KeepAwakeDefaultsKey.pauseWhenLocked)
        var battery = KeepAwakeBatteryInfo(percent: 50, isCharging: false, isOnBattery: true)
        let writes = LidWrites()
        let manager = KeepAwakeManager(
            defaults: defaults, monitorSystem: false, clamshellWrite: writes.write,
            clamshellConfigured: true, batterySnapshot: { battery }
        )
        manager.whileAgentsWork = true
        manager.recoverIfNeeded()
        manager.screenLockStateDidChange(locked: true)
        manager.agentActivityDidChange(hasWorkingAgent: true)
        #expect(manager.isActive)
        #expect(!manager.isPausedForScreenLock)
        await writes.finish()
        battery = KeepAwakeBatteryInfo(percent: 10, isCharging: false, isOnBattery: true)
        manager.syncWithPreferences()
        #expect(!manager.isActive, "Battery protection outranks agent work")
        await writes.finish()
        manager.syncWithPreferences()
        #expect(!manager.isActive, "Battery cutoff cannot immediately restart automation")
        #expect(writes.pending.isEmpty)
        battery = KeepAwakeBatteryInfo(percent: 10, isCharging: true, isOnBattery: false)
        manager.syncWithPreferences()
        #expect(manager.isActive, "Power recovery can resume the unfinished agent")
        await writes.finish()
        manager.agentActivityDidChange(hasWorkingAgent: false)
        #expect(!manager.isActive, "The last agent releases sleep even while locked")
        await writes.finish()
    }

    @Test
    func testQuitDuringPendingEnableRestoresBeforeLateCallback() async {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let writes = LidWrites()
        var restoredSynchronously = false
        let manager = KeepAwakeManager(
            defaults: defaults, monitorSystem: false, clamshellWrite: writes.write,
            clamshellRestoreSync: { restoredSynchronously = true; return true },
            clamshellConfigured: true, batterySnapshot: { nil }
        )
        manager.whileAgentsWork = true
        manager.recoverIfNeeded()
        manager.agentActivityDidChange(hasWorkingAgent: true)
        manager.deactivate(reason: .quit)
        #expect(restoredSynchronously)
        #expect(!defaults.bool(forKey: KeepAwakeDefaultsKey.sleepDisabledFlag))
        await writes.finish()
        #expect(!manager.clamshellActive)
        #expect(!defaults.bool(forKey: KeepAwakeDefaultsKey.sleepDisabledFlag))
        manager.agentActivityDidChange(hasWorkingAgent: false)
        manager.agentActivityDidChange(hasWorkingAgent: true)
        #expect(!manager.isActive)
        #expect(writes.values == [true], "Late callbacks cannot re-enable sleep prevention after quit")
    }

    @Test
    func testManualStopDoesNotRestartUntilAgentsGoIdle() async {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let writes = LidWrites()
        let manager = KeepAwakeManager(
            defaults: defaults, monitorSystem: false, clamshellWrite: writes.write,
            clamshellConfigured: true, batterySnapshot: { nil }
        )
        manager.whileAgentsWork = true
        manager.recoverIfNeeded()
        manager.agentActivityDidChange(hasWorkingAgent: true)
        await writes.finish()
        manager.toggle()
        await writes.finish()
        manager.syncWithPreferences()
        #expect(!manager.isActive)
        #expect(writes.pending.isEmpty)
        manager.agentActivityDidChange(hasWorkingAgent: false)
        manager.agentActivityDidChange(hasWorkingAgent: true)
        #expect(manager.isActive)
        await writes.finish()
        manager.whileAgentsWork = false
        await writes.finish()
    }
}
