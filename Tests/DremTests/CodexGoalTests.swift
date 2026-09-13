import DremCore
import Foundation
import SQLite3
import Testing
@testable import Drem

struct CodexGoalTests {
    private enum WatchError: Error { case timedOut }
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    @Test
    func activeGoalKeepsCompletedTurnWorkingUntilTheGoalStops() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("Drem-Goal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let sessionID = "goal-session"
        let sessionDirectory = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let transcript = sessionDirectory.appendingPathComponent("\(sessionID).jsonl")
        try Data("""
        {"type":"session_meta","payload":{"id":"\(sessionID)","cwd":"/tmp/goal-project"}}
        {"timestamp":"2026-09-13T10:00:00Z","type":"event_msg","payload":{"type":"task_complete"}}
        {"timestamp":"2026-09-13T10:00:01Z","type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer"}}

        """.utf8).write(to: transcript)

        let database = home.appendingPathComponent(".codex/goals_1.sqlite")
        try writeGoal(database: database, threadID: sessionID, status: "active")
        let process = DetectedAgentProcess(
            id: 404, parentPID: 1, kind: .codex, elapsed: "01:00", state: "S", command: "codex",
            workingDirectory: "/tmp/goal-project", openTranscriptPaths: [transcript.path]
        )
        let engine = LiveActivityEngine(homeDirectory: home)

        let active = await engine.reconcile(processes: [process])
        #expect(active.snapshot.status(for: .codex).state == .working)
        #expect(active.snapshot.status(for: .codex).workingSessions.map(\.id) == [sessionID])
        #expect(ActivityLogScanner(homeDirectory: home).scan(processes: [process]).hasWorkingAgent)

        try writeGoal(database: database, threadID: sessionID, status: "blocked")
        let stopped = await engine.handleFileEvents([database.path + "-wal"])
        #expect(stopped.snapshot.status(for: .codex).state == .idle)
        #expect(!stopped.snapshot.hasWorkingAgent)
        #expect(!ActivityLogScanner(homeDirectory: home).scan(processes: [process]).hasWorkingAgent)
    }

    @Test
    func goalDatabaseWriteWakesTheEventDrivenMonitor() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("Drem-Goal-Events-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let sessionID = "event-goal-session"
        let codexDirectory = home.appendingPathComponent(".codex", isDirectory: true)
        let sessionDirectory = codexDirectory.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let transcript = sessionDirectory.appendingPathComponent("\(sessionID).jsonl")
        try Data("""
        {"type":"session_meta","payload":{"id":"\(sessionID)","cwd":"/tmp/event-goal-project"}}
        {"timestamp":"2026-09-13T10:00:00Z","type":"event_msg","payload":{"type":"task_complete"}}

        """.utf8).write(to: transcript)

        let database = codexDirectory.appendingPathComponent("goals_1.sqlite")
        try writeGoal(database: database, threadID: sessionID, status: "paused")
        let process = DetectedAgentProcess(
            id: 405, parentPID: 1, kind: .codex, elapsed: "01:00", state: "S", command: "codex",
            workingDirectory: "/tmp/event-goal-project", openTranscriptPaths: [transcript.path]
        )
        let engine = LiveActivityEngine(homeDirectory: home)
        let initial = await engine.reconcile(processes: [process])
        #expect(!initial.snapshot.hasWorkingAgent)

        let (stream, continuation) = AsyncStream<[String]>.makeStream()
        let watcher = FileSystemEventWatcher(paths: [codexDirectory.path]) {
            continuation.yield($0)
        }
        #expect(watcher.start())
        watcher.setTrackedFiles(initial.goalDatabasePaths)
        defer { watcher.stop(); continuation.finish() }

        try writeGoal(database: database, threadID: sessionID, status: "active")
        let goalPaths = Set(initial.goalDatabasePaths)
        let changedPaths = try await waitForGoalChange(stream, goalPaths: goalPaths)
        let active = await engine.handleFileEvents(changedPaths)
        #expect(active.snapshot.status(for: .codex).state == .working)
    }

    @Test(arguments: ["paused", "blocked", "usage_limited", "budget_limited", "complete"])
    func onlyActiveGoalStatusCountsAsWork(status: String) throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("Drem-Goal-Status-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let database = home.appendingPathComponent(".codex/goals_1.sqlite")

        try writeGoal(database: database, threadID: "status-session", status: status)

        let registry = CodexGoalRegistry(homeDirectory: home)
        #expect(try registry.readActiveGoals().isEmpty)
    }

    private func writeGoal(database: URL, threadID: String, status: String) throws {
        try FileManager.default.createDirectory(
            at: database.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var connection: OpaquePointer?
        guard sqlite3_open(database.path, &connection) == SQLITE_OK, let connection else {
            throw SQLiteTestError.open
        }
        defer { sqlite3_close(connection) }

        guard sqlite3_exec(connection, "PRAGMA journal_mode=WAL", nil, nil, nil) == SQLITE_OK else {
            throw SQLiteTestError.query
        }

        let schema = """
        CREATE TABLE IF NOT EXISTS thread_goals (
            thread_id TEXT PRIMARY KEY NOT NULL,
            goal_id TEXT NOT NULL,
            objective TEXT NOT NULL,
            status TEXT NOT NULL,
            token_budget INTEGER,
            tokens_used INTEGER NOT NULL DEFAULT 0,
            time_used_seconds INTEGER NOT NULL DEFAULT 0,
            created_at_ms INTEGER NOT NULL,
            updated_at_ms INTEGER NOT NULL
        );
        """
        guard sqlite3_exec(connection, schema, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteTestError.query
        }

        let statement = """
        INSERT INTO thread_goals (
            thread_id, goal_id, objective, status, created_at_ms, updated_at_ms
        ) VALUES (?, 'goal', 'private objective', ?, 1, 2)
        ON CONFLICT(thread_id) DO UPDATE SET status = excluded.status, updated_at_ms = 2;
        """
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(connection, statement, -1, &prepared, nil) == SQLITE_OK,
              let prepared else { throw SQLiteTestError.query }
        defer { sqlite3_finalize(prepared) }
        sqlite3_bind_text(prepared, 1, threadID, -1, sqliteTransient)
        sqlite3_bind_text(prepared, 2, status, -1, sqliteTransient)
        guard sqlite3_step(prepared) == SQLITE_DONE else { throw SQLiteTestError.query }
    }

    private func waitForGoalChange(
        _ stream: AsyncStream<[String]>,
        goalPaths: Set<String>
    ) async throws -> [String] {
        try await withThrowingTaskGroup(of: [String].self) { group in
            group.addTask {
                for await paths in stream where !goalPaths.isDisjoint(with: paths) {
                    return paths
                }
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

    private enum SQLiteTestError: Error {
        case open
        case query
    }
}
