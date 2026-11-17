import Foundation

public enum AgentAttention: String, Codable, Sendable {
    case permission, question

    public var title: String {
        switch self {
        case .permission: return "Ждёт разрешения"
        case .question: return "Ждёт ответа"
        }
    }
}

/// Presentation evidence only. Never used to classify activity or own sleep.
public struct AgentActivityDetail: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        case working, reading, editing, tool, compacting

        public var title: String {
            switch self {
            case .working: return "Работает"
            case .reading: return "Читает файл"
            case .editing: return "Редактирует файл"
            case .tool: return "Использует инструмент"
            case .compacting: return "Сжимает контекст"
            }
        }
    }

    public var action: Action
    public var fileName: String?
    public var publicStatus: String?
    public var confirmedAt: Date?
    public var headline: String?
    public var attention: AgentAttention?
    // Only opaque call identities and evidence times; never question/tool inputs.
    var attentionCallIDs: [String]?
    var attentionQuestionMessageIDs: [String: String]?
    var attentionUpdatedAt: Date?
    var attentionContinuationAt: Date?

    public init(action: Action = .working, fileName: String? = nil,
                publicStatus: String? = nil, confirmedAt: Date? = nil, headline: String? = nil,
                attention: AgentAttention? = nil) {
        self.action = action
        self.fileName = fileName
        self.publicStatus = publicStatus
        self.confirmedAt = confirmedAt
        self.headline = headline
        self.attention = attention
    }
}

/// Consumes only bytes already read by the activity scanner. Tool arguments
/// are never retained. Only the explicit public Codex summary heading is used;
/// its body, raw reasoning/thinking, tool output and user text are ignored.
public enum AgentDetailParser {
    public static func consume(_ text: String, kind: AgentKind,
                               previous: AgentActivityDetail? = nil) -> AgentActivityDetail? {
        consume(JSONObjects.lines(in: text), kind: kind, previous: previous)
    }

    static func consume(_ objects: [[String: Any]], kind: AgentKind,
                        previous: AgentActivityDetail? = nil) -> AgentActivityDetail? {
        var detail = previous
        for object in objects {
            let type = object["type"] as? String ?? ""
            let payload = object["payload"] as? [String: Any] ?? [:]
            let payloadType = payload["type"] as? String ?? ""
            if kind == .codex {
                if type == "turn_context" || (type == "event_msg" &&
                    ["task_started", "task_complete", "turn_aborted"].contains(payloadType)) {
                    detail = nil
                }
                // Codex's TUI spinner uses this short bold heading. Rollouts
                // persist completed summaries, so this may lag the live stream.
                let summaries: [String]
                if type == "response_item", payloadType == "reasoning" {
                    summaries = (payload["summary"] as? [[String: Any]] ?? [])
                        .filter { $0["type"] as? String == "summary_text" }
                        .compactMap { $0["text"] as? String }
                } else if type == "event_msg", payloadType == "item_completed",
                          let item = payload["item"] as? [String: Any], item["type"] as? String == "Reasoning" {
                    summaries = item["summary_text"] as? [String] ?? []
                } else { summaries = [] }
                if let headline = summaries.compactMap(codexHeadline).last {
                    var next = detail ?? AgentActivityDetail()
                    next.headline = headline
                    next.confirmedAt = timestamp(object)
                    detail = next
                }
                guard type == "response_item" else { continue }
                if payloadType == "message", payload["role"] as? String == "user" {
                    detail = nil
                } else if payloadType == "message", payload["role"] as? String == "assistant" {
                    if payload["phase"] as? String == "final_answer" { detail = nil; continue }
                    guard payload["phase"] as? String == "commentary" else { continue }
                    let content = payload["content"] as? [[String: Any]] ?? []
                    let status = content.filter { $0["type"] as? String == "output_text" }
                        .compactMap { $0["text"] as? String }.joined(separator: " ")
                    if let status = clean(status, limit: 240) {
                        var next = detail ?? AgentActivityDetail()
                        next.publicStatus = status
                        next.confirmedAt = timestamp(object)
                        detail = next
                    }
                } else if ["function_call", "custom_tool_call"].contains(payloadType) {
                    detail = tool(name: payload["name"] as? String ?? "",
                                  input: payload["arguments"] ?? payload["input"],
                                  previous: detail, at: timestamp(object))
                } else if ["function_call_output", "custom_tool_call_output", "reasoning"].contains(payloadType) {
                    detail?.action = .working
                    detail?.fileName = nil
                }
            } else {
                if type == "user" {
                    let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]]
                    if content?.contains(where: { $0["type"] as? String == "tool_result" }) == true {
                        detail?.action = .working
                        detail?.fileName = nil
                    } else { detail = nil }
                }
                guard type == "assistant", let message = object["message"] as? [String: Any] else { continue }
                if message["stop_reason"] as? String == "end_turn" { detail = nil; continue }
                for block in message["content"] as? [[String: Any]] ?? [] {
                    if block["type"] as? String == "text", let status = clean(block["text"] as? String, limit: 240) {
                        var next = detail ?? AgentActivityDetail()
                        next.publicStatus = status
                        next.confirmedAt = timestamp(object)
                        detail = next
                    } else if block["type"] as? String == "tool_use" {
                        detail = tool(name: block["name"] as? String ?? "", input: block["input"],
                                      previous: detail, at: timestamp(object))
                    }
                }
            }
        }
        return AgentAttentionParser.consume(objects, kind: kind, previous: previous, detail: detail)
    }

    private static func tool(name: String, input: Any?, previous: AgentActivityDetail?,
                             at: Date?) -> AgentActivityDetail {
        var arguments = input as? [String: Any]
        if arguments == nil, let text = input as? String, text.utf8.count < 65_536,
           let data = text.data(using: .utf8) {
            arguments = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        let leaf = name.split(separator: ".").last.map(String.init) ?? name
        let action: AgentActivityDetail.Action
        switch leaf.lowercased() {
        case "read", "read_file": action = .reading
        case "edit", "write", "multiedit", "apply_patch": action = .editing
        default: action = .tool
        }
        let path = action == .reading || action == .editing
            ? (arguments?["file_path"] ?? arguments?["path"]) as? String : nil
        let file = path.map { URL(fileURLWithPath: $0).lastPathComponent }
        return AgentActivityDetail(action: action, fileName: clean(file, limit: 80),
                                   publicStatus: previous?.publicStatus, confirmedAt: at,
                                   headline: previous?.headline)
    }

    private static func codexHeadline(_ text: String) -> String? {
        let prefix = String(text.prefix(256)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard prefix.hasPrefix("**") else { return nil }
        let tail = prefix.dropFirst(2)
        guard let end = tail.range(of: "**") else { return nil }
        let heading = String(tail[..<end.lowerBound])
        guard heading.count <= 120, !heading.contains("\n"), !heading.contains("\r") else { return nil }
        return clean(heading, limit: 120)
    }

    private static func timestamp(_ object: [String: Any]) -> Date? {
        guard let string = object["timestamp"] as? String else { return nil }
        return TranscriptActivityEvidence(state: .working, timestamp: string).timestamp
    }

    private static func clean(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let prefix = String(text.prefix(2_048))
        let safe = prefix.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
        }
        let compact = String(String.UnicodeScalarView(safe))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !compact.isEmpty else { return nil }
        return String(compact.prefix(limit)) + (compact.count > limit ? "…" : "")
    }
}
