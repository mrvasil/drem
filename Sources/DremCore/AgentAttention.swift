import Foundation

/// An independent reducer: activity, public commentary and token accounting
/// cannot create or resolve a question. All memory is bounded and input-free.
enum AgentAttentionParser {
    static func consume(_ objects: [[String: Any]], kind: AgentKind,
                        previous: AgentActivityDetail?, detail: AgentActivityDetail?) -> AgentActivityDetail? {
        var pending = previous?.attentionCallIDs ?? []
        var questionMessages = previous?.attentionQuestionMessageIDs ?? [:]
        var changedAt = previous?.attentionUpdatedAt
        var continuedAt = previous?.attentionContinuationAt
        var terminal = false

        func identity(_ value: Any?) -> String? {
            guard let value = value as? String, !value.isEmpty, value.utf8.count <= 256 else { return nil }
            return value
        }
        func start(_ value: Any?, at: Date?, messageID: String? = nil) {
            guard let id = identity(value), let at, at >= (changedAt ?? .distantPast),
                  !pending.contains(id), pending.count < 64 else { return }
            pending.append(id)
            questionMessages[id] = messageID
            changedAt = at
        }
        func resolve(_ value: Any?, at: Date?) {
            guard let id = identity(value), pending.contains(id), let at,
                  at >= (changedAt ?? .distantPast) else { return }
            pending.removeAll { $0 == id }
            questionMessages.removeValue(forKey: id)
            changedAt = at
        }
        func reset(at: Date?) {
            pending.removeAll()
            questionMessages.removeAll()
            changedAt = at ?? changedAt
            continuedAt = at ?? continuedAt
            terminal = true
        }
        func continuation(at: Date?) {
            if let at { continuedAt = max(continuedAt ?? at, at) }
            terminal = false
        }

        for object in objects {
            let at = (object["timestamp"] as? String).flatMap {
                TranscriptActivityEvidence(state: .working, timestamp: $0).timestamp
            }
            let type = object["type"] as? String ?? ""
            if kind == .codex {
                let payload = object["payload"] as? [String: Any] ?? [:]
                let event = payload["type"] as? String ?? ""
                if type == "turn_context" || (type == "event_msg" &&
                    ["task_started", "task_complete", "turn_aborted"].contains(event)) {
                    reset(at: at)
                }
                // Current Codex can issue nonblocking questions. A function call
                // alone also precedes validation, so only the explicit event proves a wait.
                if type == "event_msg", event == "request_user_input",
                   payload["isBlocking"] as? Bool == true {
                    start(payload["call_id"], at: at)
                    terminal = false
                }
                guard type == "response_item" else { continue }
                if ["function_call_output", "custom_tool_call_output"].contains(event) {
                    resolve(payload["call_id"], at: at)
                } else if ["reasoning", "function_call", "custom_tool_call"].contains(event) {
                    continuation(at: at)
                } else if event == "message", payload["role"] as? String == "user" ||
                            (event == "message" && payload["phase"] as? String == "final_answer") {
                    reset(at: at)
                }
            } else {
                let message = object["message"] as? [String: Any] ?? [:]
                let blocks = message["content"] as? [[String: Any]] ?? []
                if type == "user" {
                    let results = blocks.filter { $0["type"] as? String == "tool_result" }
                    if results.isEmpty { reset(at: at) }
                    for result in results { resolve(result["tool_use_id"], at: at) }
                } else if type == "assistant" {
                    if message["stop_reason"] as? String == "end_turn" { reset(at: at); continue }
                    let messageID = identity(message["id"])
                    let hasContinuation = blocks.contains {
                        ["thinking", "tool_use"].contains($0["type"] as? String ?? "")
                    }
                    // Claude streams sibling blocks in distinct transcript records.
                    // Only a strictly newer *model message* proves continuation;
                    // the record UUID or a new block timestamp alone does not.
                    // Resolve the prior batch before adding any questions in this one.
                    if hasContinuation, let messageID, let at,
                       at > (changedAt ?? .distantPast) {
                        let resolved = pending.filter { id in
                            questionMessages[id].map { $0 != messageID } ?? false
                        }
                        if !resolved.isEmpty {
                            pending.removeAll { resolved.contains($0) }
                            for id in resolved { questionMessages.removeValue(forKey: id) }
                            changedAt = at
                        }
                    }
                    for block in blocks {
                        let blockType = block["type"] as? String
                        if blockType == "thinking" || blockType == "tool_use" {
                            continuation(at: at)
                        }
                        if blockType == "tool_use", block["name"] as? String == "AskUserQuestion" {
                            start(block["id"], at: at, messageID: messageID)
                        }
                    }
                }
            }
        }
        if terminal && detail == nil { return nil }
        guard detail != nil || !pending.isEmpty || changedAt != nil || continuedAt != nil else { return nil }
        var result = detail ?? AgentActivityDetail()
        result.attention = pending.isEmpty ? nil : .question
        result.attentionCallIDs = pending.isEmpty ? nil : pending
        result.attentionQuestionMessageIDs = questionMessages.isEmpty ? nil : questionMessages
        result.attentionUpdatedAt = changedAt
        result.attentionContinuationAt = continuedAt
        return result
    }
}
