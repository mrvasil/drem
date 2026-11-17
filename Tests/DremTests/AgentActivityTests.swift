@testable import DremCore
import Foundation
import IOKit.pwr_mgt
import Testing
@testable import Drem

@MainActor
struct AgentActivityTests {
    private enum WatchError: Error { case timedOut }

    private func kernelAssertionIDs() throws -> Set<UInt32> {
        var value: Unmanaged<CFDictionary>?
        #expect(IOPMCopyAssertionsByProcess(&value) == kIOReturnSuccess)
        let processes = try #require(value?.takeRetainedValue() as? [NSNumber: [[String: Any]]])
        let current = processes[NSNumber(value: ProcessInfo.processInfo.processIdentifier)] ?? []
        return Set(current.compactMap { ($0["AssertionId"] as? NSNumber)?.uint32Value })
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func waitForChange(_ stream: AsyncStream<[String]>, path: String) async throws -> [String] {
        try await withThrowingTaskGroup(of: [String].self) { group in
            group.addTask {
                for await paths in stream where paths.contains(path) { return paths }
                throw WatchError.timedOut
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw WatchError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    @Test
    func initialEmptyScanFinishesLoadingAndOldRevisionsCannotRestoreWork() {
        let monitor = AgentMonitor(startAutomatically: false)
        func state(_ revision: UInt64, working: Bool = false) -> LiveActivityState {
            let snapshot = AgentSnapshot(statuses: working ? [
                AgentStatus(kind: .codex, state: .working, runningProcessCount: 1, sessions: [])
            ] : AgentSnapshot.empty.statuses)
            return LiveActivityState(revision: revision, snapshot: snapshot, processIDs: [],
                transcriptPaths: [], goalDatabasePaths: [], needsProcessReconciliation: false)
        }
        monitor.apply(state(1))
        #expect(monitor.snapshot.capturedAt != .distantPast)
        monitor.apply(state(2, working: true))
        #expect(monitor.snapshot.hasWorkingAgent)
        monitor.apply(state(4))
        monitor.apply(state(3, working: true))
        #expect(!monitor.snapshot.hasWorkingAgent)
    }

    @Test
    func inactivityDeadlineReleasesActualKernelAssertions() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("Drem-Expiry-\(UUID())")
        let directory = home.appendingPathComponent(".codex/sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let log = directory.appendingPathComponent("expiry.jsonl")
        try Data("""
        {"type":"session_meta","payload":{"id":"expiry","cwd":"/tmp/expiry"}}
        {"timestamp":"2026-09-13T10:00:00Z","type":"event_msg","payload":{"type":"task_started"}}

        """.utf8).write(to: log)
        let process = DetectedAgentProcess(id: 99117, parentPID: 1, kind: .codex, elapsed: "01:00", state: "S",
            command: "codex", openTranscriptPaths: [log.path])
        let current = LiveActivityEngine(homeDirectory: home, now: { Date(timeIntervalSince1970: 1_789_293_601) })
        let expired = LiveActivityEngine(homeDirectory: home, now: { Date(timeIntervalSince1970: 1_789_294_500) })
        let suite = "DremExpiry.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: KeepAwakeDefaultsKey.allowDisplaySleep)
        var lidWrites: [Bool] = []
        let manager = KeepAwakeManager(defaults: defaults, monitorSystem: false,
            clamshellWrite: { enabled, completion in lidWrites.append(enabled); completion(true) },
            clamshellRestoreSync: { true }, clamshellConfigured: true, batterySnapshot: { nil })
        defer { manager.deactivate(reason: .quit) }
        manager.recoverIfNeeded()
        let working = await current.reconcile(processes: [process]).snapshot.hasWorkingAgent
        let before = try kernelAssertionIDs()
        manager.agentActivityDidChange(hasWorkingAgent: working)
        manager.whileAgentsWork = true
        let owned = try kernelAssertionIDs().subtracting(before)
        await drainMainQueue()
        #expect(owned.count == 2)
        #expect(lidWrites == [true])
        manager.agentActivityDidChange(hasWorkingAgent: await expired.reconcile(processes: [process]).snapshot.hasWorkingAgent)
        await drainMainQueue()
        #expect(!manager.isActive)
        #expect(lidWrites == [true, false])
        #expect(owned.isDisjoint(with: try kernelAssertionIDs()))
    }

    @Test
    func fileEventsDetectTaskStartAndCompletionDespiteAnOldIdleHook() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("Drem-Events-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let directory = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let log = directory.appendingPathComponent("session.jsonl")
        try Data("""
        {"type":"session_meta","payload":{"id":"event-session","cwd":"/tmp/event-project"}}
        {"timestamp":"2020-01-01T00:00:00Z","type":"event_msg","payload":{"type":"task_complete"}}

        """.utf8).write(to: log)
        let hook = try JSONDecoder().decode(HookInput.self, from: Data("""
        {"session_id":"event-session","cwd":"/tmp/event-project","hook_event_name":"SessionStart"}
        """.utf8))
        try HookStateStore(homeDirectory: home).record(input: hook, kind: .codex, processID: nil)
        let process = DetectedAgentProcess(
            id: 9191, parentPID: 91, kind: .codex, elapsed: "00:01", state: "S", command: "codex",
            workingDirectory: "/tmp/event-project", openTranscriptPaths: [log.path]
        )
        let engine = LiveActivityEngine(homeDirectory: home)
        let initial = await engine.reconcile(processes: [process])
        #expect(!initial.snapshot.hasWorkingAgent)

        let suite = "DremEvents.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: KeepAwakeDefaultsKey.clamshellPreferred)
        defaults.set(false, forKey: KeepAwakeDefaultsKey.allowDisplaySleep)
        var lidWrites: [Bool] = []
        let manager = KeepAwakeManager(
            defaults: defaults, monitorSystem: false,
            clamshellWrite: { enabled, completion in lidWrites.append(enabled); completion(true) },
            clamshellRestoreSync: { true }, clamshellConfigured: true, batterySnapshot: { nil }
        )
        defer { manager.deactivate(reason: .quit) }
        manager.recoverIfNeeded()
        let previousAssertions = try kernelAssertionIDs()
        manager.activate(minutes: 0, trigger: .manual)
        let ownedAssertions = try kernelAssertionIDs().subtracting(previousAssertions)
        #expect(ownedAssertions.count == 2, "Real system and display assertions were created")
        await drainMainQueue()
        #expect(lidWrites == [true])

        let (stream, continuation) = AsyncStream<[String]>.makeStream()
        let watcher = FileSystemEventWatcher(paths: [directory.path]) { continuation.yield($0) }
        #expect(watcher.start())
        watcher.setTrackedFiles(initial.transcriptPaths)
        defer { watcher.stop(); continuation.finish() }

        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let stamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(1))
        try handle.write(contentsOf: Data("""
        {"timestamp":"\(stamp)","type":"event_msg","payload":{"type":"task_started"}}

        """.utf8))
        let startPaths = try await waitForChange(stream, path: log.path)
        let started = await engine.handleFileEvents(startPaths)
        #expect(started.snapshot.hasWorkingAgent)
        #expect(started.snapshot.status(for: .codex).workingSessions.first?.id == "event-session")
        manager.agentActivityDidChange(hasWorkingAgent: started.snapshot.hasWorkingAgent)
        manager.whileAgentsWork = true
        #expect(manager.sessionTrigger == .automation)
        #expect(ownedAssertions.isSubset(of: try kernelAssertionIDs()), "Ownership transfer keeps the same kernel assertions")

        let compactionInput = try JSONDecoder().decode(HookInput.self, from: Data("""
        {"session_id":"event-session","cwd":"/tmp/event-project","hook_event_name":"PreCompact","trigger":"auto"}
        """.utf8))
        let compactDate = Date().addingTimeInterval(2)
        try HookStateStore(homeDirectory: home).record(
            input: compactionInput, kind: .codex, processID: nil, now: compactDate
        )
        let compactStamp = ISO8601DateFormatter().string(from: compactDate.addingTimeInterval(1))
        try handle.write(contentsOf: Data("""
        {"timestamp":"\(compactStamp)","type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer"}}

        """.utf8))
        let compactPaths = try await waitForChange(stream, path: log.path)
        let compacting = await engine.handleFileEvents(compactPaths)
        #expect(compacting.snapshot.workingCount == 1)
        manager.agentActivityDidChange(hasWorkingAgent: compacting.snapshot.hasWorkingAgent)
        #expect(ownedAssertions.isSubset(of: try kernelAssertionIDs()), "Compaction keeps the original kernel assertions")
        #expect(manager.clamshellActive)
        #expect(lidWrites == [true], "Compaction must not toggle closed-lid sleep protection")

        try handle.write(contentsOf: Data("""
        {"timestamp":"\(compactStamp)","type":"event_msg","payload":{"type":"task_complete"}}

        """.utf8))
        let stopPaths = try await waitForChange(stream, path: log.path)
        let stopped = await engine.handleFileEvents(stopPaths)
        #expect(!stopped.snapshot.hasWorkingAgent)
        manager.agentActivityDidChange(hasWorkingAgent: stopped.snapshot.hasWorkingAgent)
        #expect(!manager.isActive)
        #expect(ownedAssertions.isDisjoint(with: try kernelAssertionIDs()), "The actual kernel assertions are gone, not just a UI flag")
        await drainMainQueue()
        #expect(lidWrites == [true, false])
        #expect(!manager.clamshellActive)
        #expect(!defaults.bool(forKey: KeepAwakeDefaultsKey.sleepDisabledFlag))
    }
}
