import Foundation
import Testing
@testable import DremCore

struct ActivityReliabilityTests {
    private func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Drem-Reliability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appendingPathComponent(".codex/sessions"), withIntermediateDirectories: true)
        return url
    }
    private func transcript(_ event: String, stamp: Date = Date()) -> Data {
        let timestamp = ISO8601DateFormatter().string(from: stamp)
        return Data("""
        {"type":"session_meta","payload":{"id":"reliable","cwd":"/tmp/reliable"}}
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"\(event)"}}

        """.utf8)
    }
    private func process(_ log: URL) -> DetectedAgentProcess {
        DetectedAgentProcess(id: 98765, parentPID: 1, kind: .codex, elapsed: "01:00", state: "S", command: "codex",
                             workingDirectory: "/tmp/reliable", openTranscriptPaths: [log.path])
    }

    @Test func silentLiveProcessDoesNotHoldSleepForever() async throws {
        let home = try home(); defer { try? FileManager.default.removeItem(at: home) }
        let log = home.appendingPathComponent(".codex/sessions/reliable.jsonl")
        try transcript("task_started", stamp: Date().addingTimeInterval(-3600)).write(to: log)
        let engine = LiveActivityEngine(homeDirectory: home)
        let state = await engine.reconcile(processes: [process(log)])
        #expect(!state.snapshot.hasWorkingAgent)
        #expect(state.snapshot.status(for: .codex).runningProcessCount == 1)
    }

    @Test func sameSizeAtomicTranscriptReplacementIsReparsed() throws {
        let home = try home(); defer { try? FileManager.default.removeItem(at: home) }
        let log = home.appendingPathComponent(".codex/sessions/reliable.jsonl")
        let now = Date()
        let started = transcript("task_started", stamp: now) + Data(" ".utf8)
        let complete = transcript("task_complete", stamp: now)
        #expect(started.count == complete.count)
        try started.write(to: log, options: .atomic)
        let scanner = IncrementalTranscriptScanner()
        #expect(scanner.consume(url: log, kind: .codex)?.session.state == .working)
        try complete.write(to: log, options: .atomic)
        #expect(scanner.consume(url: log, kind: .codex)?.session.state == .idle)
    }

    @Test func deletedTranscriptCannotLeaveCachedWork() async throws {
        let home = try home(); defer { try? FileManager.default.removeItem(at: home) }
        let log = home.appendingPathComponent(".codex/sessions/reliable.jsonl")
        try transcript("task_started").write(to: log)
        let engine = LiveActivityEngine(homeDirectory: home)
        #expect(await engine.reconcile(processes: [process(log)]).snapshot.hasWorkingAgent)
        try FileManager.default.removeItem(at: log)
        #expect(!(await engine.handleFileEvents([log.path])).snapshot.hasWorkingAgent)
    }
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        func read() -> Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) { lock.lock(); value.addTimeInterval(seconds); lock.unlock() }
    }

    @Test func watchdogExpiresAtFifteenMinutesAndFreshWorkRestartsIt() async throws {
        let home = try home(); defer { try? FileManager.default.removeItem(at: home) }
        let log = home.appendingPathComponent(".codex/sessions/reliable.jsonl")
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        try transcript("task_started", stamp: clock.read()).write(to: log)
        let engine = LiveActivityEngine(homeDirectory: home, now: { clock.read() })
        #expect(await engine.reconcile(processes: [process(log)]).snapshot.hasWorkingAgent)
        clock.advance(899)
        #expect(await engine.recheckTrackedTranscripts().snapshot.hasWorkingAgent)
        clock.advance(1)
        #expect(!(await engine.recheckTrackedTranscripts()).snapshot.hasWorkingAgent)
        // A full rescan and a meaningless write cannot renew stale work.
        #expect(!(await engine.reconcile(processes: [process(log)])).snapshot.hasWorkingAgent)
        let handle = try FileHandle(forWritingTo: log); defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\"}}\n".utf8))
        #expect(!(await engine.handleFileEvents([log.path])).snapshot.hasWorkingAgent)
        // The watchdog repairs a missed start event from an existing journal.
        try transcript("task_started", stamp: clock.read()).write(to: log, options: .atomic)
        #expect(await engine.recheckTrackedTranscripts().snapshot.hasWorkingAgent)
        try transcript("task_complete", stamp: clock.read()).write(to: log, options: .atomic)
        #expect(!(await engine.recheckTrackedTranscripts()).snapshot.hasWorkingAgent)
    }

    @Test func unchangedHooksAreNotDecodedAndReplacementDeletionAreObserved() throws {
        let home = try home(); defer { try? FileManager.default.removeItem(at: home) }
        let store = HookStateStore(homeDirectory: home)
        let input = try JSONDecoder().decode(HookInput.self, from: Data(
            "{\"session_id\":\"cache\",\"cwd\":\"/tmp/cache\",\"hook_event_name\":\"UserPromptSubmit\"}".utf8))
        try store.record(input: input, kind: .codex, processID: 123)
        let cache = HookStateCache(store: store)
        cache.refresh()
        #expect(cache.records.count == 1)
        #expect(cache.decodedFileCount == 1)
        for _ in 0..<20 { cache.refresh() }
        #expect(cache.decodedFileCount == 1)
        try store.record(input: input, kind: .codex, processID: 456)
        cache.refresh()
        #expect(cache.records.first?.processID == 456)
        #expect(cache.decodedFileCount == 2)
        store.removeSession(kind: .codex, sessionID: "cache")
        cache.refresh()
        #expect(cache.records.isEmpty)
    }

    @Test func eventRoutingExcludesNoiseAndRequestsRecoveryForRootEvents() async throws {
        let home = try home(); defer { try? FileManager.default.removeItem(at: home) }
        let paths = ActivityEventPaths(homeDirectory: home)
        #expect(!paths.contains(home.appendingPathComponent(".codex/log/codex-tui.log").path))
        #expect(!paths.contains(home.appendingPathComponent(".codex/goals_1.sqlite-shm").path))
        #expect(paths.contains(home.appendingPathComponent(".codex/goals_1.sqlite-wal").path))
        #expect(paths.contains(home.appendingPathComponent(".claude/sessions/123.json").path))
        let state = await LiveActivityEngine(homeDirectory: home).handleFileEvents([home.appendingPathComponent(".codex").path])
        #expect(state.needsProcessReconciliation)
    }

    @Test func suspendedProcessDoesNotHoldSleepAndResumeIsDetected() async throws {
        let home = try home(); defer { try? FileManager.default.removeItem(at: home) }
        let log = home.appendingPathComponent(".codex/sessions/reliable.jsonl")
        try transcript("task_started").write(to: log)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { kill(child.processIdentifier, SIGCONT); child.terminate(); child.waitUntilExit() }
        let pid = child.processIdentifier
        let detected = DetectedAgentProcess(id: pid, parentPID: getpid(), kind: .codex, elapsed: "00:00",
            state: "S", command: "codex", openTranscriptPaths: [log.path], startedAt: ProcessLiveness.startTime(pid))
        let engine = LiveActivityEngine(homeDirectory: home)
        #expect(await engine.reconcile(processes: [detected]).snapshot.hasWorkingAgent)
        #expect(kill(pid, SIGSTOP) == 0)
        for _ in 0..<50 where ProcessLiveness.canMakeProgress(pid, startedAt: detected.startedAt) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(!(await engine.recheckTrackedTranscripts(validateProcesses: true)).snapshot.hasWorkingAgent)
        #expect(kill(pid, SIGCONT) == 0)
        for _ in 0..<50 where !ProcessLiveness.canMakeProgress(pid, startedAt: detected.startedAt) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await engine.recheckTrackedTranscripts(validateProcesses: true).snapshot.hasWorkingAgent)
        #expect(!ProcessLiveness.canMakeProgress(pid, startedAt: Date(timeIntervalSince1970: 1)))
    }

    @Test func backwardsWallClockCannotExtendAStalledLease() async throws {
        let home = try home(); defer { try? FileManager.default.removeItem(at: home) }
        let log = home.appendingPathComponent(".codex/sessions/reliable.jsonl")
        let wall = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let elapsed = Clock(Date(timeIntervalSince1970: 100))
        try transcript("task_started", stamp: wall.read()).write(to: log)
        let engine = LiveActivityEngine(homeDirectory: home, now: { wall.read() },
                                       uptime: { elapsed.read().timeIntervalSince1970 })
        #expect(await engine.reconcile(processes: [process(log)]).snapshot.hasWorkingAgent)
        wall.advance(-3600); elapsed.advance(900)
        #expect(!(await engine.recheckTrackedTranscripts()).snapshot.hasWorkingAgent)
        #expect(!(await engine.reconcile(processes: [process(log)])).snapshot.hasWorkingAgent)
    }

}
