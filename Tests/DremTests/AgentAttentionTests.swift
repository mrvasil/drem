import Foundation
import Testing
@testable import DremCore

@Suite struct AgentAttentionTests {
    private func line(_ object: [String: Any], _ second: Int = 1) -> String {
        var object = object
        object["timestamp"] = "2026-09-19T12:00:\(String(format: "%02d", second)).000Z"
        return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    private func question(_ id: String, _ second: Int = 1, name: String = "AskUserQuestion") -> String {
        line(["type": "assistant", "message": ["content": [
            ["type": "tool_use", "name": name, "id": id, "input": ["questions": ["private question"]]]
        ]]], second)
    }

    private func result(_ id: String, _ second: Int = 2) -> String {
        line(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": id, "content": "private answer"]]]], second)
    }

    private func time(_ second: Int) -> Date {
        TranscriptActivityEvidence(state: .working, timestamp: "2026-09-19T12:00:\(String(format: "%02d", second)).000Z").timestamp!
    }

    private func session(_ detail: AgentActivityDetail?, _ second: Int = 1,
                         source: ActivitySource = .transcript, state: AgentActivity = .working) -> AgentSessionActivity {
        AgentSessionActivity(id: "s", kind: .claude, state: state, updatedAt: time(second),
            projectName: "fixture", processID: 42, source: source, detail: detail)
    }

    @Test func questionMatchesExactToolAndResultIdentity() {
        let first = AgentDetailParser.consume(question("q1"), kind: .claude)
        #expect(first?.attention == .question)
        let two = AgentDetailParser.consume(question("q2", 2), kind: .claude, previous: first)
        let unrelated = AgentDetailParser.consume(result("other", 3), kind: .claude, previous: two)
        #expect(unrelated?.attentionCallIDs == ["q1", "q2"])
        let partial = AgentDetailParser.consume(result("q1", 4), kind: .claude, previous: unrelated)
        #expect(partial?.attention == .question)
        #expect(partial?.attentionCallIDs == ["q2"])
        #expect(AgentDetailParser.consume(result("q2", 5), kind: .claude, previous: partial)?.attention == nil)
        #expect(AgentDetailParser.consume(question("q", name: "mcp__example__AskUserQuestion"), kind: .claude)?.attention == nil)
        #expect(AgentDetailParser.consume(question("q", name: "request_user_input_async"), kind: .claude)?.attention == nil)
    }

    @Test func textAndUnrelatedCommentaryCannotCreateOrClearAttention() {
        let text = line(["type": "assistant", "message": ["content": [["type": "text", "text": "AskUserQuestion permission_prompt waiting for approval?"]]]], 2)
        #expect(AgentDetailParser.consume(text, kind: .claude)?.attention == nil)
        let pending = AgentDetailParser.consume(question("q"), kind: .claude)
        #expect(AgentDetailParser.consume(text, kind: .claude, previous: pending)?.attention == .question)
        let encoded = String(data: try! JSONEncoder().encode(pending), encoding: .utf8)!
        #expect(!encoded.contains("private question"))
        #expect(!encoded.contains("questions"))
    }

    @Test func codexRequiresExplicitBlockingRequestAndMatchingResult() {
        let bare = line(["type": "response_item", "payload": ["type": "function_call", "name": "request_user_input", "call_id": "q"]])
        #expect(AgentDetailParser.consume(bare, kind: .codex)?.attention == nil)
        for flag: Any in [false, "true", NSNull()] {
            let event = line(["type": "event_msg", "payload": ["type": "request_user_input", "call_id": "q", "isBlocking": flag]])
            #expect(AgentDetailParser.consume(event, kind: .codex)?.attention == nil)
        }
        let event = line(["type": "event_msg", "payload": ["type": "request_user_input", "call_id": "q", "isBlocking": true]])
        let pending = AgentDetailParser.consume(event, kind: .codex)
        #expect(pending?.attention == .question)
        let heartbeat = line(["type": "event_msg", "payload": ["type": "token_count"]], 2)
        #expect(AgentDetailParser.consume(heartbeat, kind: .codex, previous: pending)?.attention == .question)
        let output = line(["type": "response_item", "payload": ["type": "function_call_output", "call_id": "q"]], 3)
        #expect(AgentDetailParser.consume(output, kind: .codex, previous: pending)?.attention == nil)
        for terminal in ["task_complete", "turn_aborted", "task_started"] {
            #expect(AgentDetailParser.consume(line(["type": "event_msg", "payload": ["type": terminal]], 3), kind: .codex, previous: pending)?.attention == nil)
        }
    }

    @Test func oldJSONAndTerminalLifecycleRemainCompatible() throws {
        let old = Data(#"{"action":"working"}"#.utf8)
        #expect(try JSONDecoder().decode(AgentActivityDetail.self, from: old).attention == nil)
        let pending = AgentDetailParser.consume(question("q"), kind: .claude)
        let end = line(["type": "assistant", "message": ["stop_reason": "end_turn"]], 3)
        #expect(AgentDetailParser.consume(end, kind: .claude, previous: pending) == nil)
        #expect(AgentDetailParser.consume(line(["type": "user", "message": ["content": "new turn"]], 3), kind: .claude, previous: pending)?.attention == nil)
        let oldHook = Data(#"{"sessionID":"s","kind":"claude","state":"working","updatedAt":0,"cwd":"/fixture","eventName":"UserPromptSubmit"}"#.utf8)
        #expect(try JSONDecoder().decode(HookStateRecord.self, from: oldHook).attention == nil)
    }

    @Test func permissionHookDoesNotChangeActivityAndRejectsUnconfirmedEvents() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = HookStateStore(homeDirectory: home)
        func record(_ event: String, _ second: Int, notification: String? = nil, kind: AgentKind = .claude) throws {
            var input: [String: Any] = ["session_id": "s", "cwd": "/fixture", "hook_event_name": event]
            input["notification_type"] = notification
            let decoded = try JSONDecoder().decode(HookInput.self, from: JSONSerialization.data(withJSONObject: input))
            try store.record(input: decoded, kind: kind, processID: 42, now: time(second))
        }
        try record("Notification", 1, notification: "permission_prompt")
        #expect(store.readAll().isEmpty)
        try record("UserPromptSubmit", 1)
        for event in ["PermissionRequest", "Unknown"] { try record(event, 2) }
        try record("Notification", 2, notification: "idle_prompt")
        #expect(store.readAll().first?.detail?.attention == nil)
        try record("Notification", 3, notification: "permission_prompt")
        #expect(store.readAll().first?.detail?.attention == .permission)
        #expect(store.readAll().first?.updatedAt == time(1))
        #expect(store.readValid(processes: []).isEmpty)
        try record("Stop", 4)
        #expect(store.readAll().first?.state == .idle)
        #expect(store.readAll().first?.detail == nil)
        try record("Notification", 5, notification: "permission_prompt")
        #expect(store.readAll().first?.state == .idle)
        try record("SessionEnd", 6)
        #expect(store.readAll().isEmpty)
    }

    @Test func mergeUsesAttentionEvidenceNotCommentaryOrActivityClock() {
        var permission = AgentActivityDetail(confirmedAt: time(2), attention: .permission)
        permission.attentionUpdatedAt = time(2)
        let hook = session(permission, source: .hook)
        let commentary = line(["type": "assistant", "message": ["content": [["type": "text", "text": "status"]]]], 3)
        let text = AgentDetailParser.consume(commentary, kind: .claude)
        #expect(AgentActivityEvidence.merge(hooks: [hook], transcripts: [session(text, 3)]).first?.detail?.attention == .permission)
        let unrelated = AgentDetailParser.consume(result("other", 4), kind: .claude, previous: text)
        #expect(AgentActivityEvidence.merge(hooks: [hook], transcripts: [session(unrelated, 4)]).first?.detail?.attention == .permission)
        let continuation = AgentDetailParser.consume(question("tool", 5, name: "Read"), kind: .claude, previous: unrelated)
        #expect(AgentActivityEvidence.merge(hooks: [hook], transcripts: [session(continuation, 5)]).first?.detail?.attention == nil)
        let question = AgentDetailParser.consume(question("q", 3), kind: .claude)
        #expect(AgentActivityEvidence.merge(hooks: [hook], transcripts: [session(question, 3)]).first?.detail?.attention == .question)
        let resolved = AgentDetailParser.consume(result("q", 4), kind: .claude, previous: question)
        #expect(AgentActivityEvidence.merge(hooks: [hook], transcripts: [session(resolved, 4)]).first?.detail?.attention == nil)
        let compact = session(AgentActivityDetail(action: .compacting, confirmedAt: time(5)), 5, source: .hook)
        #expect(AgentActivityEvidence.merge(hooks: [compact], transcripts: [session(question, 3)]).first?.detail?.attention == nil)
        let stop = session(nil, 5, source: .hook, state: .idle)
        let ended = AgentActivityEvidence.merge(hooks: [stop], transcripts: [session(question, 3)])
        #expect(ended.first?.state == .idle)
        #expect(ended.first?.detail == nil)
    }

    @Test func unrelatedQuestionResultCannotResolveNewerPermissionPrompt() {
        let pending = AgentDetailParser.consume(question("q", 1), kind: .claude)
        var permission = AgentActivityDetail(confirmedAt: time(2), attention: .permission)
        permission.attentionUpdatedAt = time(2)
        let resolved = AgentDetailParser.consume(result("q", 3), kind: .claude, previous: pending)
        let merged = AgentActivityEvidence.merge(hooks: [session(permission, source: .hook)],
                                                transcripts: [session(resolved, 3)])
        #expect(merged.first?.detail?.attention == .permission)
    }

    @Test func goalsAndProcessLifetimeDoNotResurrectStaleAttention() {
        let stale = AgentSessionActivity(id: "s", kind: .codex, state: .idle, updatedAt: time(1),
            projectName: nil, processID: 42, source: .transcript,
            detail: AgentActivityDetail(attention: .question))
        let goal = AgentActivityEvidence.applyingActiveCodexGoals([stale], activeGoals: ["s": time(3)])
        #expect(goal.first?.state == .working)
        #expect(goal.first?.detail?.attention == nil)
        let oldProcess = session(AgentActivityDetail(attention: .permission))
        let newProcess = AgentActivityEvidence.forProcessLifetime(oldProcess, startedAt: time(5))
        #expect(newProcess.state == .idle)
        #expect(newProcess.detail == nil)
    }

    @Test func staleQuestionReplayAndOldDetailsDoNotOverrideNewerEvidence() {
        let pending = AgentDetailParser.consume(question("q", 1), kind: .claude)
        let resolved = AgentDetailParser.consume(result("q", 3), kind: .claude, previous: pending)
        #expect(AgentDetailParser.consume(question("q", 1), kind: .claude, previous: resolved)?.attention == nil)
        let start = session(nil, 4, source: .hook)
        let merged = AgentActivityEvidence.merge(hooks: [start], transcripts: [session(pending, 1)])
        #expect(merged.first?.detail == nil)
    }

    @Test func newAssistantMessageResolvesWaitButSiblingBlocksAndCommentaryDoNot() {
        func assistant(_ id: String, _ second: Int, _ blocks: [[String: Any]]) -> String {
            line(["type": "assistant", "message": ["id": id, "content": blocks]], second)
        }
        func ask(_ id: String) -> [String: Any] {
            ["type": "tool_use", "name": "AskUserQuestion", "id": id]
        }
        let read: [String: Any] = ["type": "tool_use", "name": "Read", "id": "read"]
        let thinking: [String: Any] = ["type": "thinking", "thinking": "private reasoning"]
        let first = AgentDetailParser.consume(assistant("m1", 1, [ask("q1"), read, ask("q2")]), kind: .claude)
        #expect(first?.attentionCallIDs == ["q1", "q2"])
        // Transcript fragments of a streamed message have separate record UUIDs
        // and timestamps but the same model message.id.
        let siblings = AgentDetailParser.consume(assistant("m1", 2, [thinking, ask("q3")]), kind: .claude, previous: first)
        #expect(siblings?.attentionCallIDs == ["q1", "q2", "q3"])
        let commentary = AgentDetailParser.consume(assistant("m2", 3, [["type": "text", "text": "status"]]), kind: .claude, previous: siblings)
        #expect(commentary?.attentionCallIDs == ["q1", "q2", "q3"])
        let unrelated = AgentDetailParser.consume(result("other", 4), kind: .claude, previous: commentary)
        #expect(unrelated?.attentionCallIDs == ["q1", "q2", "q3"])
        let resumed = AgentDetailParser.consume(assistant("m2", 5, [thinking]), kind: .claude, previous: unrelated)
        #expect(resumed?.attention == nil)
        #expect(resumed?.attentionCallIDs == nil)
        let newBatch = AgentDetailParser.consume(assistant("m3", 6, [ask("q4"), read, ask("q5")]), kind: .claude, previous: siblings)
        #expect(newBatch?.attentionCallIDs == ["q4", "q5"])
        let oldBatch = AgentDetailParser.consume(assistant("old", 1, [read]), kind: .claude, previous: newBatch)
        #expect(oldBatch?.attentionCallIDs == ["q4", "q5"])
        #expect(oldBatch?.attentionContinuationAt == time(6))
        let unknownBatch = AgentDetailParser.consume(line(["type": "assistant", "message": ["content": [thinking]]], 7), kind: .claude, previous: newBatch)
        #expect(unknownBatch?.attentionCallIDs == ["q4", "q5"])
        let sameTime = AgentDetailParser.consume(assistant("m4", 6, [read]), kind: .claude, previous: newBatch)
        #expect(sameTime?.attentionCallIDs == ["q4", "q5"])
        let encoded = try! JSONEncoder().encode(newBatch)
        let decoded = try! JSONDecoder().decode(AgentActivityDetail.self, from: encoded)
        let afterReload = AgentDetailParser.consume(assistant("m4", 7, [read]), kind: .claude, previous: decoded)
        #expect(afterReload?.attention == nil)
        let legacy = AgentDetailParser.consume(question("old-q", 1), kind: .claude)
        let noOrigin = AgentDetailParser.consume(assistant("m2", 2, [thinking]), kind: .claude, previous: legacy)
        #expect(noOrigin?.attentionCallIDs == ["old-q"])
    }
}
