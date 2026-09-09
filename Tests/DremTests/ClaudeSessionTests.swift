import DremCore
import Foundation
import Testing

struct ClaudeSessionTests {
    private let activeID = "11111111-1111-4111-8111-111111111111"
    private let idleID = "22222222-2222-4222-8222-222222222222"

    @Test
    func resumedProcessDoesNotInheritWorkFromBeforeItStarted() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("Drem-Claude-Resume-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let logs = home.appendingPathComponent(".claude/projects/project", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let log = logs.appendingPathComponent("\(activeID).jsonl")
        try Data("""
        {"type":"assistant","sessionId":"\(activeID)","cwd":"/tmp/project","timestamp":"2019-12-31T23:59:00Z","message":{"stop_reason":"tool_use"}}

        """.utf8).write(to: log)
        let store = HookStateStore(homeDirectory: home)
        try FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
        try Data("""
        {"sessionID":"\(activeID)","kind":"claude","cwd":"/tmp/project","state":"working","eventName":"UserPromptSubmit","updatedAt":"2019-12-31T23:59:30Z"}
        """.utf8).write(to: store.directoryURL.appendingPathComponent("claude-\(activeID).json"))
        let process = DetectedAgentProcess(
            id: 1001, parentPID: 1, kind: .claude, elapsed: "00:01", state: "S", command: "claude",
            workingDirectory: "/tmp/project", sessionIDHint: activeID,
            startedAt: Date(timeIntervalSince1970: 1_577_836_800.25)
        )
        let engine = LiveActivityEngine(homeDirectory: home)
        #expect(!(await engine.reconcile(processes: [process])).snapshot.hasWorkingAgent)
        #expect(!(await engine.recheckTrackedTranscripts()).snapshot.hasWorkingAgent)
        #expect(!ActivityLogScanner(homeDirectory: home).scan(processes: [process]).hasWorkingAgent)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("""
        {"type":"user","sessionId":"\(activeID)","cwd":"/tmp/project","timestamp":"2020-01-01T00:00:00Z"}

        """.utf8))
        #expect((await engine.handleFileEvents([log.path])).snapshot.workingCount == 1,
                "Second-resolution hook/log timestamps can equal the process start second")
    }

    @Test(arguments: [false, true])
    func registryBindsClaudeWithoutAnOpenLogAmongSeveralSameDirectoryProcesses(reusedPID: Bool) async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("Drem-Claude-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let registry = home.appendingPathComponent(".claude/sessions", isDirectory: true)
        let logs = home.appendingPathComponent(".claude/projects/-tmp-project", isDirectory: true)
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        var processes: [DetectedAgentProcess] = []
        for (index, id) in [activeID, idleID].enumerated() {
            let pid = Int32(1001 + index)
            try Data("""
            {"pid":\(pid),"sessionId":"\(id)","cwd":"/tmp/project","procStart":"Wed Jan  1 00:00:00 2020","pidDomain":"darwin","status":"idle"}
            """.utf8).write(to: registry.appendingPathComponent("\(pid).json"))
            let stop = index == 0 ? "tool_use" : "end_turn"
            try Data("""
            {"type":"assistant","sessionId":"\(id)","cwd":"/tmp/project","timestamp":"2020-01-02T00:00:00Z","message":{"stop_reason":"\(stop)"}}

            """.utf8).write(to: logs.appendingPathComponent("\(id).jsonl"))
            processes.append(DetectedAgentProcess(
                id: pid, parentPID: 1, kind: .claude, elapsed: "00:01", state: "S", command: "claude",
                workingDirectory: "/tmp/project",
                startedAt: Date(timeIntervalSince1970: 1_577_836_800.25 + (reusedPID && index == 0 ? 60 : 0))
            ))
        }
        let engine = LiveActivityEngine(homeDirectory: home)
        let initial = await engine.reconcile(processes: processes)
        #expect(initial.snapshot.status(for: .claude).workingSessions.map(\.id) == (reusedPID ? [] : [activeID]))
        #expect(initial.snapshot.status(for: .claude).workingSessions.first?.processID == (reusedPID ? nil : 1001))
        #expect(initial.snapshot.workingCount == (reusedPID ? 0 : 1))
        for id in [activeID, idleID] {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)],
                                                 ofItemAtPath: logs.appendingPathComponent("\(id).jsonl").path)
        }
        for index in 0..<41 {
            try Data("{}\n".utf8).write(to: logs.appendingPathComponent("history-\(index).jsonl"))
        }
        let rediscovered = await engine.reconcile(processes: processes)
        #expect(rediscovered.snapshot.workingCount == (reusedPID ? 0 : 1),
                "Registry-bound logs must survive the recent-history limit")
        #expect(rediscovered.snapshot.status(for: .claude).sessions.count == (reusedPID ? 1 : 2))
        // Registry status is deliberately idle: it provides identity, not the
        // task activity. The semantic transcript remains authoritative.
        let log = logs.appendingPathComponent("\(activeID).jsonl")
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("""
        {"type":"assistant","sessionId":"\(activeID)","cwd":"/tmp/project","timestamp":"2020-01-03T00:00:00Z","message":{"stop_reason":"end_turn"}}

        """.utf8))
        let completed = await engine.recheckTrackedTranscripts()
        #expect(!completed.snapshot.hasWorkingAgent)
        #expect(completed.snapshot.status(for: .claude).sessions.count == (reusedPID ? 1 : 2))

        let statusOnly = await engine.handleFileEvents([registry.appendingPathComponent("1002.json").path])
        #expect(!statusOnly.needsProcessReconciliation, "A status-only registry event must not spawn ps/lsof")
        // A new process registration must request discovery even before its
        // first transcript or hook event arrives.
        let newRegistration = registry.appendingPathComponent("1003.json")
        try Data("{}".utf8).write(to: newRegistration)
        let discovered = await engine.handleFileEvents([newRegistration.path])
        #expect(discovered.needsProcessReconciliation)
    }
}
