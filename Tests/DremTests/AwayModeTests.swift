import DremCore
import Foundation
import Testing
@testable import Drem

@MainActor
struct AwayModeTests {
    private final class LidWrites {
        var pending: [(Bool) -> Void] = []

        func write(_: Bool, completion: @escaping (Bool) -> Void) {
            pending.append(completion)
        }

        func finish() async {
            guard !pending.isEmpty else {
                Issue.record("Expected a pending system write")
                return
            }
            pending.removeFirst()(true)
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private final class LockRequests {
        var primaryAvailable = true
        var fallbackAvailable = true
        var primaryCount = 0
        var fallbackCount = 0

        var locker: SystemScreenLocker {
            SystemScreenLocker(
                canRequestPrimary: { [self] in primaryAvailable },
                canRequestFallback: { [self] in fallbackAvailable },
                requestPrimary: { [self] in primaryCount += 1; return primaryAvailable },
                requestFallback: { [self] in fallbackCount += 1; return fallbackAvailable }
            )
        }
    }

    private final class ScheduledWork {
        var items: [DispatchWorkItem] = []
        func schedule(_: TimeInterval, _ item: DispatchWorkItem) { items.append(item) }
        func runNext() { items.removeFirst().perform() }
    }

    private func preferences() -> (UserDefaults, String) {
        let suite = "DremAwayModeTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test
    func closingRequestsOneSystemLockAndConfirmsIt() {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = KeepAwakeManager(defaults: defaults, monitorSystem: false,
                                       clamshellConfigured: true, batterySnapshot: { nil })
        let requests = LockRequests()
        let scheduled = ScheduledWork()
        var locked = false
        let controller = AwayModeController(
            keepAwake: manager, locker: requests.locker,
            isScreenLocked: { locked }, schedule: scheduled.schedule
        )
        defer { controller.shutdown(); manager.deactivate(reason: .quit) }

        manager.awayModeEnabled = true
        controller.startWithoutSystemObservers()
        controller.lidStateDidChange(false)
        controller.lidStateDidChange(true)
        controller.lidStateDidChange(true)

        #expect(requests.primaryCount == 1)
        #expect(requests.fallbackCount == 0)
        #expect(controller.state == .locking)
        locked = true
        scheduled.runNext()
        #expect(controller.state == .locked)
        #expect(controller.lastError == nil)
    }

    @Test
    func unconfirmedPrimaryFallsBackAndNeverClaimsFalseProtection() {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = KeepAwakeManager(defaults: defaults, monitorSystem: false,
                                       clamshellConfigured: true, batterySnapshot: { nil })
        let requests = LockRequests()
        let scheduled = ScheduledWork()
        let controller = AwayModeController(
            keepAwake: manager, locker: requests.locker,
            isScreenLocked: { false }, schedule: scheduled.schedule
        )
        defer { controller.shutdown(); manager.deactivate(reason: .quit) }

        manager.awayModeEnabled = true
        controller.startWithoutSystemObservers()
        controller.lidStateDidChange(false)
        controller.lidStateDidChange(true)
        scheduled.runNext()
        #expect(requests.primaryCount == 1)
        #expect(requests.fallbackCount == 1)
        #expect(controller.state == .locking)
        scheduled.runNext()
        #expect(controller.state == .failed)
        #expect(controller.lastError != nil)
    }

    @Test
    func awayModeNeverOwnsWakeAndLastAgentStillReleasesTheLid() async {
        let (defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let writes = LidWrites()
        let manager = KeepAwakeManager(
            defaults: defaults, monitorSystem: false, clamshellWrite: writes.write,
            clamshellConfigured: true, batterySnapshot: { nil }
        )
        defer { manager.deactivate(reason: .quit) }
        manager.awayModeEnabled = true
        manager.recoverIfNeeded()
        #expect(!manager.isActive)
        manager.whileAgentsWork = true
        manager.agentActivityDidChange(hasWorkingAgent: true)
        #expect(manager.isActive)
        await writes.finish()
        #expect(manager.clamshellActive)
        manager.screenLockStateDidChange(locked: true)
        #expect(!manager.isPausedForScreenLock)
        manager.agentActivityDidChange(hasWorkingAgent: false)
        await writes.finish()
        #expect(!manager.isActive)
        #expect(!manager.clamshellActive)
        #expect(manager.awayModeEnabled, "Security preference remains armed without owning sleep")
    }

    @Test
    func lockedAwayModeLetsOnlyTheDisplaySleep() {
        #expect(KeepAwakeAgentPolicy.shouldAllowDisplaySleep(
            userPreference: false, awayModeEnabled: true, screenLocked: true
        ))
        #expect(!KeepAwakeAgentPolicy.shouldAllowDisplaySleep(
            userPreference: false, awayModeEnabled: true, screenLocked: false
        ))
        #expect(KeepAwakeAgentPolicy.shouldAllowDisplaySleep(
            userPreference: true, awayModeEnabled: false, screenLocked: false
        ))
    }
}
