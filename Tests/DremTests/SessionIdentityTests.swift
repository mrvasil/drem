import DremCore
import Foundation
import Testing

struct SessionIdentityTests {
    @Test(arguments: [false, true])
    func boundSessionsAreNotHiddenByNewerLogsInTheSameFolder(olderIsWorking: Bool) async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("Drem-Bound-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var processes: [DetectedAgentProcess] = []
        for (index, id) in ["older", "newer"].enumerated() {
            let log = directory.appendingPathComponent("\(id).jsonl")
            let event = index == 0 && !olderIsWorking ? "task_complete" : "task_started"
            // The older session predates the project rename, but its open file
            // still identifies it exactly. Both live processes share the new cwd.
            let cwd = index == 0 ? "/tmp/old-project" : "/tmp/shared-project"
            try Data("""
            {"type":"session_meta","payload":{"id":"\(id)","cwd":"\(cwd)"}}
            {"timestamp":"2020-01-02T00:00:00Z","type":"event_msg","payload":{"type":"\(event)"}}

            """.utf8).write(to: log)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index + 1))], ofItemAtPath: log.path)
            processes.append(DetectedAgentProcess(
                id: Int32(101 + index), parentPID: 1, kind: .codex, elapsed: "01:00", state: "S", command: "codex",
                workingDirectory: "/tmp/shared-project", openTranscriptPaths: [log.path]
            ))
        }
        let store = HookStateStore(homeDirectory: home)
        try FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
        try Data("""
        {"sessionID":"older","kind":"codex","cwd":"/tmp/shared-project","state":"working","eventName":"UserPromptSubmit","updatedAt":"2020-01-01T00:00:00Z"}
        """.utf8).write(to: store.directoryURL.appendingPathComponent("codex-older.json"))
        // Unrelated recent history must not push an open session out of the
        // bounded discovery window.
        for index in 0..<41 {
            try Data("{}\n".utf8).write(to: directory.appendingPathComponent("history-\(index).jsonl"))
        }
        let engine = LiveActivityEngine(homeDirectory: home)
        let state = await engine.reconcile(processes: processes)
        #expect(state.snapshot.workingCount == (olderIsWorking ? 2 : 1))
        #expect(Set(state.snapshot.status(for: .codex).sessions.map(\.id)) == ["older", "newer"])
        #expect(Set(state.transcriptPaths).isSuperset(of: processes.flatMap(\.openTranscriptPaths)))
        let fallback = ActivityLogScanner(homeDirectory: home).scan(processes: processes)
        #expect(fallback.workingCount == (olderIsWorking ? 2 : 1))
    }

    @Test
    func hookUsesTheOpenSessionIdentityAfterTheProjectIsRenamed() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("Drem-Renamed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = HookStateStore(homeDirectory: home)
        try FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
        try Data("""
        {"sessionID":"renamed-session","kind":"codex","cwd":"/tmp/new-project","state":"working","eventName":"UserPromptSubmit","updatedAt":"2020-01-01T00:00:00Z"}
        """.utf8).write(to: store.directoryURL.appendingPathComponent("codex-renamed-session.json"))
        let process = DetectedAgentProcess(
            id: 101, parentPID: 1, kind: .codex, elapsed: "01:00", state: "S", command: "codex",
            workingDirectory: "/tmp/new-project",
            openTranscriptPaths: [home.appendingPathComponent(".codex/sessions/rollout-2020-01-01T00-00-00-renamed-session.jsonl").path]
        )
        let engine = LiveActivityEngine(homeDirectory: home)
        let initial = await engine.reconcile(processes: [process])
        #expect(initial.snapshot.workingCount == 1)
        #expect(initial.snapshot.status(for: .codex).sessions.first?.processID == 101)
        let exited = await engine.processExited(101)
        #expect(!exited.snapshot.hasWorkingAgent)
    }

    @Test(arguments: [1, 2])
    func orphanedHookCannotBorrowAnotherSessionInTheSameDirectory(processCount: Int) async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("Drem-Identity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("active.jsonl")
        try Data("""
        {"type":"session_meta","payload":{"id":"active","cwd":"/tmp/shared-project"}}
        {"timestamp":"2020-01-02T00:00:00Z","type":"event_msg","payload":{"type":"task_started"}}

        """.utf8).write(to: log)
        let store = HookStateStore(homeDirectory: home)
        try FileManager.default.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
        try Data("""
        {"sessionID":"orphan","kind":"codex","cwd":"/tmp/shared-project","state":"working","eventName":"UserPromptSubmit","updatedAt":"2020-01-01T00:00:00Z"}
        """.utf8).write(to: store.directoryURL.appendingPathComponent("codex-orphan.json"))
        var processes = [DetectedAgentProcess(
            id: 101, parentPID: 1, kind: .codex, elapsed: "01:00", state: "S", command: "codex",
            workingDirectory: "/tmp/shared-project", openTranscriptPaths: [log.path]
        )]
        if processCount == 2 {
            processes.append(DetectedAgentProcess(
                id: 102, parentPID: 1, kind: .codex, elapsed: "01:00", state: "S", command: "codex",
                workingDirectory: "/tmp/shared-project"
            ))
        }

        let engine = LiveActivityEngine(homeDirectory: home)
        let initial = await engine.reconcile(processes: processes)
        #expect(initial.snapshot.workingCount == 1)
        #expect(initial.snapshot.status(for: .codex).sessions.map(\.id) == ["active"])
        let event = await engine.handleFileEvents([log.path])
        #expect(event.snapshot.workingCount == 1)
        let watchdog = await engine.recheckTrackedTranscripts()
        #expect(watchdog.snapshot.workingCount == 1)

        let unrelated = directory.appendingPathComponent("unrelated.jsonl")
        try Data("""
        {"type":"session_meta","payload":{"id":"unrelated","cwd":"/tmp/shared-project"}}
        {"timestamp":"2020-01-01T00:00:00Z","type":"event_msg","payload":{"type":"task_started"}}

        """.utf8).write(to: unrelated)
        let unrelatedEvent = await engine.handleFileEvents([unrelated.path])
        #expect(unrelatedEvent.snapshot.workingCount == 1, "An old log cannot borrow the live session's PID either")

        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("""
        {"timestamp":"2020-01-02T00:01:00Z","type":"event_msg","payload":{"type":"task_complete"}}

        """.utf8))
        let finished = await engine.handleFileEvents([log.path])
        #expect(finished.snapshot.workingCount == 0)
        #expect(!finished.snapshot.hasWorkingAgent)
        #expect(store.readAll().count == 1, "Unbound history is ignored, not deleted")
    }
}
