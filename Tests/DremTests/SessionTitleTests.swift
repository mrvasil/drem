import DremCore
import Foundation
import Testing

struct SessionTitleTests {
    @Test func savedCodexNameUpdatesByExactIdentityWithoutChangingActivity() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("Drem-Titles-\(UUID())")
        let directory = home.appendingPathComponent(".codex/sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let log = directory.appendingPathComponent("one.jsonl")
        let index = home.appendingPathComponent(".codex/session_index.jsonl")
        try Data("""
        {"type":"session_meta","payload":{"id":"one","cwd":"/tmp/demo"}}
        {"type":"event_msg","payload":{"type":"task_started"}}

        """.utf8).write(to: log)
        try Data("""
        {"id":"one","thread_name":"Design the island"}
        {"id":"unrelated","thread_name":"Never borrow this"}

        """.utf8).write(to: index)
        let process = DetectedAgentProcess(id: 303, parentPID: 1, kind: .codex, elapsed: "01:00",
            state: "S", command: "codex", workingDirectory: "/tmp/demo", openTranscriptPaths: [log.path])
        let engine = LiveActivityEngine(homeDirectory: home)
        let initial = await engine.reconcile(processes: [process])
        #expect(initial.snapshot.status(for: .codex).workingSessions.first?.sessionTitle == "Design the island")
        #expect(initial.goalDatabasePaths.contains(index.path))
        let handle = try FileHandle(forWritingTo: index)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"id\":\"one\",\"thread_name\":\"Refine drem\"}\n".utf8))
        let renamed = await engine.handleFileEvents([index.path])
        #expect(renamed.snapshot.status(for: .codex).workingSessions.first?.sessionTitle == "Refine drem")
        #expect(renamed.snapshot.workingCount == 1)
        #expect(!renamed.needsProcessReconciliation)
    }

    @Test func claudeTitleSurvivesTurnBoundariesAndDoesNotUseSummaryText() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Drem-Claude-Title-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("session.jsonl")
        try Data("""
        {"sessionId":"one","cwd":"/tmp/demo","type":"user","message":{"content":"private request"}}
        {"type":"custom-title","customTitle":"Improve settings"}
        {"type":"summary","summary":"private compacted conversation"}

        """.utf8).write(to: log)
        let scanner = IncrementalTranscriptScanner()
        #expect(scanner.consume(url: log, kind: .claude)?.session.sessionTitle == "Improve settings")
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"assistant\",\"message\":{\"stop_reason\":\"end_turn\"}}\n".utf8))
        let ended = scanner.consume(url: log, kind: .claude)?.session
        #expect(ended?.state == .idle)
        #expect(ended?.sessionTitle == "Improve settings")
        #expect(SessionTitle.clean(String(repeating: "x", count: 200))?.count == 96)
        #expect(SessionTitle.clean("\u{202E}Safe\u{0007}") == "Safe")
    }
}
