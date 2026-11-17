import DremCore
import Foundation
import Testing

struct CompactionTests {
    private func input(_ event: String, source: String? = nil, trigger: String? = nil,
                       session: String = "compacting") throws -> HookInput {
        var fields = ["session_id": session, "cwd": "/tmp/project", "hook_event_name": event]
        fields["source"] = source
        fields["trigger"] = trigger
        return try JSONDecoder().decode(HookInput.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    @Test(arguments: AgentKind.allCases, ["manual", "auto"])
    func compactionHooksKeepWorkAndRestoreTheCorrectState(kind: AgentKind, trigger: String) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("Drem-Compact-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let store = HookStateStore(homeDirectory: home)
        try store.record(input: input("SessionStart", source: "startup"), kind: kind, processID: 303)
        if trigger == "auto" {
            try store.record(input: input("UserPromptSubmit"), kind: kind, processID: 303)
        }
        try store.record(input: input("PreCompact", trigger: trigger), kind: kind, processID: 303)
        #expect(store.readAll().first?.state == .working, "Compacting is work, even from an idle prompt")
        #expect(store.readAll().first?.eventName == "PreCompact")
        #expect(store.readAll().first?.detail?.action == .compacting)

        try store.record(input: input("PostCompact", trigger: trigger), kind: kind, processID: 303)
        let expected: AgentActivity = trigger == "auto" ? .working : .idle
        #expect(store.readAll().first?.state == expected)
        try store.record(input: input("SessionStart", source: "compact"), kind: kind, processID: 303)
        #expect(store.readAll().first?.state == expected, "Post-compact SessionStart is not a fresh idle session")

        try store.record(input: input("Stop"), kind: kind, processID: 303)
        #expect(store.readAll().first?.state == .idle)
        try store.record(input: input("SessionEnd"), kind: kind, processID: 303)
        #expect(store.readAll().isEmpty)
    }

    @Test(arguments: AgentKind.allCases, ["startup", "resume", "clear"])
    func realSessionStartDoesNotInheritCompaction(kind: AgentKind, source: String) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("Drem-Compact-Start-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let store = HookStateStore(homeDirectory: home)
        try store.record(input: input("PreCompact", trigger: "auto"), kind: kind, processID: 303)
        try store.record(input: input("SessionStart", source: source), kind: kind, processID: 303)
        #expect(store.readAll().first?.state == .idle)
        #expect(store.readAll().first?.compactionStartedAt == nil)
    }

    @Test(arguments: ["Interrupt", "Stop", "StopFailure"])
    func terminalHookClearsCompactionAndLateSessionStartCannotReviveIt(event: String) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("Drem-Compact-End-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let store = HookStateStore(homeDirectory: home)
        try store.record(input: input("PreCompact", trigger: "auto"), kind: .codex, processID: 303)
        try store.record(input: input(event), kind: .codex, processID: 303)
        try store.record(input: input("SessionStart", source: "compact"), kind: .codex, processID: 303)
        #expect(store.readAll().first?.state == .idle)
        #expect(store.readAll().first?.compactionStartedAt == nil)
    }

    @Test(arguments: AgentKind.allCases)
    func olderClientCanFinishCompactionWithoutPostCompact(kind: AgentKind) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("Drem-Compact-Old-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let store = HookStateStore(homeDirectory: home)
        // A compact-only SessionStart must not manufacture an idle/working record.
        try store.record(input: input("SessionStart", source: "compact"), kind: kind, processID: 303)
        #expect(store.readAll().isEmpty)
        for trigger in ["auto", "manual"] {
            try store.record(input: input("PreCompact", trigger: trigger), kind: kind, processID: 303)
            try store.record(input: input("SessionStart", source: "compact"), kind: kind, processID: 303)
            #expect(store.readAll().first?.state == (trigger == "auto" ? .working : .idle))
            #expect(store.readAll().first?.compactionStartedAt == nil)
        }
    }

    @Test(arguments: AgentKind.allCases, ["auto", "manual"])
    func summaryFinalDoesNotStopCompactionButAnActualEndDoes(kind: AgentKind, trigger: String) async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("Drem-Compact-Summary-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent(kind == .codex ? ".codex/sessions" : ".claude/projects")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("compacting.jsonl")
        let metadata = kind == .codex
            ? #"{"type":"session_meta","payload":{"id":"compacting","cwd":"/tmp/project"}}"#
            : #"{"type":"system","sessionId":"compacting","cwd":"/tmp/project"}"#
        let started = kind == .codex
            ? #"{"timestamp":"2026-09-18T12:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}"#
            : #"{"timestamp":"2026-09-18T12:00:00.000Z","type":"user"}"#
        try Data("\(metadata)\n\(started)\n".utf8).write(to: log)
        let process = DetectedAgentProcess(id: 303, parentPID: 1, kind: kind, elapsed: "01:00",
            state: "S", command: kind.rawValue, workingDirectory: "/tmp/project", openTranscriptPaths: [log.path])
        let store = HookStateStore(homeDirectory: home)
        let date = try #require(ISO8601DateFormatter().date(from: "2026-09-18T12:00:01Z"))
        try store.record(input: input("PreCompact", trigger: trigger), kind: kind, processID: 303, now: date)
        let engine = LiveActivityEngine(homeDirectory: home)
        #expect(await engine.reconcile(processes: [process]).snapshot.workingCount == 1)
        // Prime the incremental cursor, then flush the synthetic summary alone.
        _ = await engine.handleFileEvents([log.path])
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let summary = kind == .codex
            ? #"{"timestamp":"2026-09-18T12:00:01.100Z","type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer"}}"#
            : #"{"timestamp":"2026-09-18T12:00:01.100Z","type":"assistant","message":{"stop_reason":"end_turn"}}"#
        try handle.write(contentsOf: Data("\(summary)\n".utf8))
        #expect(await engine.handleFileEvents([log.path]).snapshot.workingCount == 1,
                "A compaction summary is not completion of the user's task")
        #expect(await engine.recheckTrackedTranscripts().snapshot.workingCount == 1)
        #expect(await LiveActivityEngine(homeDirectory: home).reconcile(processes: [process]).snapshot.workingCount == 1,
                "Restarting drem mid-compaction must preserve work")
        #expect(ActivityLogScanner(homeDirectory: home).scan(processes: [process]).workingCount == 1)

        if kind == .codex {
            for (index, event) in ["task_complete", "turn_aborted"].enumerated() {
                let fraction = index == 0 ? "110" : "130"
                try handle.write(contentsOf: Data("""
                {"timestamp":"2026-09-18T12:00:01.\(fraction)Z","type":"event_msg","payload":{"type":"\(event)"}}

                """.utf8))
                #expect(await engine.handleFileEvents([log.path]).snapshot.workingCount == 0,
                        "An explicit task end beats a still-present PreCompact record")
                try store.record(input: input("PreCompact", trigger: trigger), kind: kind, processID: 303,
                                 now: date.addingTimeInterval(index == 0 ? 0.12 : 0.14))
                #expect(await engine.handleFileEvents([store.directoryURL.path]).snapshot.workingCount == 1)
            }
        }

        try store.record(input: input("PostCompact", trigger: trigger), kind: kind, processID: 303,
                         now: date.addingTimeInterval(0.2))
        try store.record(input: input("SessionStart", source: "compact"), kind: kind, processID: 303,
                         now: date.addingTimeInterval(0.3))
        #expect(await engine.handleFileEvents([store.directoryURL.path]).snapshot.workingCount == (trigger == "auto" ? 1 : 0))
        // Termination must still beat compaction, including subsecond ordering.
        try store.record(input: input("Stop"), kind: kind, processID: 303, now: date.addingTimeInterval(0.4))
        #expect(await engine.handleFileEvents([store.directoryURL.path]).snapshot.workingCount == 0)
        try store.record(input: input("PreCompact", trigger: "auto"), kind: kind, processID: 303,
                         now: date.addingTimeInterval(0.5))
        #expect(await engine.handleFileEvents([store.directoryURL.path]).snapshot.workingCount == 1)
        #expect(await engine.processExited(303).snapshot.workingCount == 0)
        #expect(store.readAll().isEmpty)
    }
}
