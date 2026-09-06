import DremCore
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

        try handle.write(contentsOf: Data("""
        {"timestamp":"\(stamp)","type":"event_msg","payload":{"type":"task_complete"}}

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
