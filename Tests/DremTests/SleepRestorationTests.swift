import DremCore
import Foundation
import Testing
@testable import Drem

@Suite(.serialized)
struct SleepRestorationTests {
    @Test(arguments: ["", "SleepDisabled 10", "OtherSleepDisabled 1", "SleepDisabled ?", "SleepDisabled 0\nSleepDisabled 1"])
    func missingOrMalformedSleepStateIsUnknown(output: String) {
        let parsed: Bool? = KeepAwakeSudoersSupport.sleepDisabledState(inPmsetOutput: output)
        #expect(parsed == nil)
    }

    @Test
    func failedEnableStillRequiresExplicitRestore() {
        var state = KeepAwakeClamshellState()
        #expect(state.request(true) == true)
        #expect(state.complete(success: false) == nil)
        #expect(state.request(false) == false,
                "A failed enable may have changed pmset before its handshake failed")
    }

    @Test
    func stopDuringFailedEnableIsReconciled() {
        var state = KeepAwakeClamshellState()
        #expect(state.request(true) == true)
        #expect(state.request(false) == nil)
        #expect(state.complete(success: false) == false,
                "The newer stop must survive a failed enable callback")
    }
    @Test
    func workResumingDuringFailedRestoreKeepsLatestDemand() {
        var state = KeepAwakeClamshellState()
        #expect(state.request(true) == true)
        #expect(state.complete(success: true) == nil)
        #expect(state.request(false) == false)
        #expect(state.request(true) == nil)
        #expect(state.complete(success: false) == true)
        #expect(!state.active, "A failed guard operation cannot confirm lid protection")
        #expect(state.restorationRequired)
    }

    @Test
    func queryFailureNeverMeansSleepIsEnabled() {
        #expect(KeepAwakeSudoers.sleepDisabledState(run: { _, _ in (-1, "SleepDisabled 0") }) == nil)
        #expect(KeepAwakeSudoers.sleepDisabledState(run: { _, _ in (1, "SleepDisabled 0") }) == nil)
        #expect(KeepAwakeSudoers.sleepDisabledState(run: { _, _ in (0, " SleepDisabled  0\n") }) == false)
        #expect(KeepAwakeSudoers.sleepDisabledState(run: { _, _ in (0, " SleepDisabled  1\n") }) == true)
    }

    @Test
    func authorizationProbeOnlyListsBothExactCommands() {
        var calls: [[String]] = []
        let configured = KeepAwakeSudoers.isConfigured(rulePresent: true) { path, arguments in
            calls.append([path] + arguments)
            return (0, "")
        }
        #expect(configured)
        #expect(calls == [
            ["/usr/bin/sudo", "-n", "-l", "/usr/bin/pmset", "disablesleep", "0"],
            ["/usr/bin/sudo", "-n", "-l", "/usr/bin/pmset", "disablesleep", "1"],
        ])
        #expect(!KeepAwakeSudoers.isConfigured(rulePresent: true) { _, arguments in
            (arguments.last == "1" ? 1 : 0, "")
        })
        #expect(!KeepAwakeSudoers.isConfigured(rulePresent: false) { _, _ in
            Issue.record("Missing rule must not run a probe")
            return (0, "")
        })
    }

    @MainActor
    private final class Writes {
        var values: [Bool] = []
        var pending: [(Bool) -> Void] = []

        func write(_ value: Bool, completion: @escaping (Bool) -> Void) {
            values.append(value)
            pending.append(completion)
        }

        func finish(_ success: Bool) async {
            guard !pending.isEmpty else {
                Issue.record("Expected pending sleep operation")
                return
            }
            pending.removeFirst()(success)
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(1)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(condition())
    }

    @Test @MainActor
    func failedEnableAfterAgentStopsStillRestores() async {
        let suite = "DremTests.SleepRestoration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let writes = Writes()
        let manager = KeepAwakeManager(
            defaults: defaults, monitorSystem: false, clamshellWrite: writes.write,
            clamshellRestoreSync: { true }, clamshellConfigured: true,
            batterySnapshot: { nil }
        )
        manager.whileAgentsWork = true
        manager.recoverIfNeeded()
        manager.agentActivityDidChange(hasWorkingAgent: true)
        manager.agentActivityDidChange(hasWorkingAgent: false)
        await writes.finish(false)
        #expect(writes.values == [true, false])
        #expect(defaults.bool(forKey: KeepAwakeDefaultsKey.sleepDisabledFlag))
        await writes.finish(true)
        #expect(!defaults.bool(forKey: KeepAwakeDefaultsKey.sleepDisabledFlag))
        #expect(!manager.clamshellActive)
        #expect(!manager.isActive)
    }

    @Test @MainActor
    func newWorkDuringFailedRestoreReestablishesProtection() async throws {
        let suite = "DremTests.SleepRestoration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let writes = Writes()
        let manager = KeepAwakeManager(
            defaults: defaults, monitorSystem: false, clamshellWrite: writes.write,
            clamshellRestoreSync: { true }, clamshellConfigured: true,
            clamshellRestoreRetryDelay: 0.01, batterySnapshot: { nil }
        )
        manager.whileAgentsWork = true
        manager.recoverIfNeeded()
        manager.agentActivityDidChange(hasWorkingAgent: true)
        await writes.finish(true)
        manager.agentActivityDidChange(hasWorkingAgent: false)
        manager.agentActivityDidChange(hasWorkingAgent: true)
        await writes.finish(false)
        #expect(writes.values == [true, false, true])
        #expect(!manager.clamshellActive)
        await writes.finish(true)
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(writes.values == [true, false, true], "No stale restore retry may stop new work")
        #expect(manager.clamshellActive)
        manager.agentActivityDidChange(hasWorkingAgent: false)
        await writes.finish(true)
        #expect(!defaults.bool(forKey: KeepAwakeDefaultsKey.sleepDisabledFlag))
    }

    @Test @MainActor
    func unknownRecoveryRetainsMarkerUntilSuccessfulRestore() async throws {
        let suite = "DremTests.SleepRestoration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: KeepAwakeDefaultsKey.sleepDisabledFlag)
        let writes = Writes()
        var completed = false
        let manager = KeepAwakeManager(
            defaults: defaults, monitorSystem: false, clamshellWrite: writes.write,
            clamshellRestoreSync: { true }, clamshellConfigured: true,
            sleepDisabledState: { nil }, clamshellRestoreRetryDelay: 0.01,
            batterySnapshot: { nil }
        )
        manager.recoverIfNeeded { completed = true }
        try await waitUntil { writes.values == [false] }
        #expect(defaults.bool(forKey: KeepAwakeDefaultsKey.sleepDisabledFlag))
        #expect(!completed)
        await writes.finish(false)
        #expect(defaults.bool(forKey: KeepAwakeDefaultsKey.sleepDisabledFlag))
        try await waitUntil { writes.values == [false, false] }
        await writes.finish(true)
        #expect(completed)
        #expect(!defaults.bool(forKey: KeepAwakeDefaultsKey.sleepDisabledFlag))
    }

    @Test @MainActor
    func failedRestoreRetriesAreBoundedAndQuitStillReconciles() async throws {
        let suite = "DremTests.SleepRestoration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: KeepAwakeDefaultsKey.sleepDisabledFlag)
        let writes = Writes()
        var synchronousRestores = 0
        let manager = KeepAwakeManager(
            defaults: defaults, monitorSystem: false, clamshellWrite: writes.write,
            clamshellRestoreSync: { synchronousRestores += 1; return true },
            clamshellConfigured: true, sleepDisabledState: { nil },
            clamshellRestoreRetryDelay: 0.01, batterySnapshot: { nil }
        )
        manager.recoverIfNeeded()
        for attempt in 1...3 {
            try await waitUntil { writes.values.count == attempt }
            await writes.finish(false)
            #expect(defaults.bool(forKey: KeepAwakeDefaultsKey.sleepDisabledFlag))
        }
        manager.deactivate(reason: .manual)
        manager.syncWithPreferences()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(writes.values == [false, false, false])
        #expect(writes.pending.isEmpty)
        #expect(manager.lastError != nil)
        manager.deactivate(reason: .quit)
        #expect(synchronousRestores == 1)
        #expect(!defaults.bool(forKey: KeepAwakeDefaultsKey.sleepDisabledFlag))
    }

    private final class QueryBarrier: @unchecked Sendable {
        private let lock = NSLock()
        private let releaseSignal = DispatchSemaphore(value: 0)
        private var entered = false

        var isEntered: Bool {
            lock.lock()
            defer { lock.unlock() }
            return entered
        }

        func query() -> Bool? {
            lock.lock()
            entered = true
            lock.unlock()
            guard releaseSignal.wait(timeout: .now() + 2) == .success else { return nil }
            return false
        }

        func release() { releaseSignal.signal() }
    }

    @Test @MainActor
    func preferenceChangesDuringStartupQueryCannotStealNewEnableCallback() async throws {
        let suite = "DremTests.SleepRestoration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: KeepAwakeDefaultsKey.sleepDisabledFlag)
        defaults.set(true, forKey: KeepAwakeDefaultsKey.clamshellPreferred)
        defaults.set(true, forKey: KeepAwakeDefaultsKey.autoStart)
        let writes = Writes()
        let query = QueryBarrier()
        defer { query.release() }
        let manager = KeepAwakeManager(
            defaults: defaults, monitorSystem: false, clamshellWrite: writes.write,
            clamshellRestoreSync: { true }, clamshellConfigured: true,
            sleepDisabledState: query.query, batterySnapshot: { nil }
        )
        defer { manager.deactivate(reason: .quit) }
        manager.recoverIfNeeded { manager.activateOnLaunchIfNeeded() }
        try await waitUntil { query.isEntered }
        manager.clamshellPreferred = false
        manager.clamshellPreferred = true
        #expect(writes.values.isEmpty, "Startup query owns cleanup until its result is reconciled")
        query.release()
        try await waitUntil { manager.isActive }
        #expect(writes.values == [true])
        await writes.finish(true)
        #expect(manager.clamshellActive)
        #expect(defaults.bool(forKey: KeepAwakeDefaultsKey.sleepDisabledFlag),
                "An older restore must never clear a newer enable's durable marker")
    }

    @Test @MainActor
    func knownRestoredRecoveryClearsMarkerWithoutSystemWrite() async throws {
        let suite = "DremTests.SleepRestoration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: KeepAwakeDefaultsKey.sleepDisabledFlag)
        let writes = Writes()
        var completed = false
        let manager = KeepAwakeManager(
            defaults: defaults, monitorSystem: false, clamshellWrite: writes.write,
            clamshellRestoreSync: { true }, clamshellConfigured: true,
            sleepDisabledState: { false }, batterySnapshot: { nil }
        )
        manager.recoverIfNeeded { completed = true }
        try await waitUntil { completed }
        #expect(writes.values.isEmpty)
        #expect(!defaults.bool(forKey: KeepAwakeDefaultsKey.sleepDisabledFlag))
    }

}
