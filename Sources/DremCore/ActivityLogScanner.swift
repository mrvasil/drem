import Foundation

public struct TranscriptActivityRecord: Sendable {
    public let session: AgentSessionActivity
    public let workingDirectory: String
    public let transcriptPath: String
}

struct TranscriptActivityEvidence {
    let state: AgentActivity
    let timestamp: Date?

    init(state: AgentActivity, timestamp: String?) {
        self.state = state
        self.timestamp = ActivityTimestamp.parse(timestamp)
    }
}

public struct ActivityLogScanner: Sendable {
    private let homeDirectory: URL
    private let now: @Sendable () -> Date
    private let tailLimit = 4 * 1_024 * 1_024
    private var fileManager: FileManager { .default }

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.homeDirectory = homeDirectory
        self.now = now
    }

    public func scan() throws -> AgentSnapshot {
        let processes = try ProcessScanner().scan()
        return scan(processes: processes)
    }

    public func scan(processes: [DetectedAgentProcess]) -> AgentSnapshot {
        let processes = ClaudeSessionRegistry(homeDirectory: homeDirectory).applying(to: processes)
        let hookSessions = HookStateStore(homeDirectory: homeDirectory).readValid(processes: processes)
        let transcriptSessions = scanTranscriptRecords(processes: processes)
        let activeCodexGoals = (try? CodexGoalRegistry(homeDirectory: homeDirectory).readActiveGoals()) ?? [:]
        let statuses = AgentKind.allCases.map { kind in
            makeStatus(
                kind: kind,
                processes: processes,
                hookSessions: hookSessions,
                transcriptSessions: transcriptSessions,
                activeCodexGoals: activeCodexGoals
            )
        }
        return AgentSnapshot(statuses: statuses)
    }

    public func scanTranscriptRecords(
        processes: [DetectedAgentProcess],
        hooks suppliedHooks: [HookStateRecord]? = nil
    ) -> [TranscriptActivityRecord] {
        let hooks = suppliedHooks ?? HookStateStore(homeDirectory: homeDirectory).readAll()
        return AgentKind.allCases.flatMap { kind in
            scanTranscripts(
                kind: kind,
                processes: processes.filter { $0.kind == kind },
                hooks: hooks
            )
        }
    }

    private func makeStatus(
        kind: AgentKind,
        processes: [DetectedAgentProcess],
        hookSessions: [AgentSessionActivity],
        transcriptSessions: [TranscriptActivityRecord],
        activeCodexGoals: [String: Date]
    ) -> AgentStatus {
        let kindProcesses = processes.filter { $0.kind == kind }
        guard !kindProcesses.isEmpty else {
            return AgentStatus(kind: kind, state: .offline, runningProcessCount: 0, sessions: [])
        }

        let merged = AgentActivityEvidence.merge(
            hooks: hookSessions.filter { $0.kind == kind },
            transcripts: transcriptSessions.map(\.session).filter { $0.kind == kind }
        ).map { session in
            AgentActivityEvidence.forProcessLifetime(
                session, startedAt: kindProcesses.first { $0.id == session.processID }?.startedAt
            )
        }
        let validGoals = activeCodexGoals.filter { id, updated in
            guard let session = merged.first(where: { $0.id == id }),
                  let process = kindProcesses.first(where: { $0.id == session.processID }) else { return false }
            return process.startedAt.map { updated.timeIntervalSince1970 >= floor($0.timeIntervalSince1970) } ?? true
        }
        let sessions = AgentActivityEvidence.expiringInactiveSessions(
            AgentActivityEvidence.applyingActiveCodexGoals(merged, activeGoals: validGoals), now: now()
        )

        return AgentStatus(
            kind: kind,
            state: sessions.contains { $0.state == .working } ? .working : .idle,
            runningProcessCount: kindProcesses.count,
            sessions: sessions
        )
    }

    private func scanTranscripts(
        kind: AgentKind,
        processes: [DetectedAgentProcess],
        hooks: [HookStateRecord]
    ) -> [TranscriptActivityRecord] {
        guard !processes.isEmpty else { return [] }

        let root: URL
        switch kind {
        case .codex:
            root = homeDirectory.appendingPathComponent(".codex/sessions", isDirectory: true)
        case .claude:
            root = homeDirectory.appendingPathComponent(".claude/projects", isDirectory: true)
        }

        // The recent-history limit is for discovery, never for files already
        // held by a live agent. An older idle session can still have a stale hook.
        let openPaths = Set(processes.flatMap(\.openTranscriptPaths).map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        })
        let openFiles: [(url: URL, modifiedAt: Date)] = openPaths.compactMap { path in
            let url = URL(fileURLWithPath: path)
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true, let date = values.contentModificationDate else { return nil }
            return (url, date)
        }
        let candidates = (openFiles + recentJSONLFiles(
            at: root, limit: 40, sessionIDs: Set(processes.compactMap(\.sessionIDHint))
        ).filter {
            !openPaths.contains($0.url.standardizedFileURL.path)
        }).sorted { $0.modifiedAt > $1.modifiedAt }
        var results: [TranscriptActivityRecord] = []
        var newestByDirectory: [String: Date] = [:]

        for candidate in candidates {
            guard let metadata = metadata(for: candidate.url, kind: kind),
                  let cwd = normalizedPath(metadata.cwd) else {
                continue
            }

            let exactProcessID = processID(
                for: candidate.url, sessionID: metadata.sessionID, cwd: cwd,
                processes: processes, allowDirectoryFallback: false
            )
            if exactProcessID == nil, let newest = newestByDirectory[cwd], newest > candidate.modifiedAt {
                continue
            }

            guard let processID = exactProcessID ?? processID(
                for: candidate.url, sessionID: metadata.sessionID, cwd: cwd, processes: processes
            ) else { continue }

            guard let tail = readTail(candidate.url) else { continue }
            let objects = JSONObjects.lines(in: tail)
            var boundary = false
            let compactingSince = hooks.first { $0.kind == kind && $0.sessionID == metadata.sessionID }?.compactionStartedAt
            guard let evidence = kind == .codex
                    ? Self.codexEvidence(objects, previousState: nil, acceptsWorkAfterBoundary: &boundary,
                                         compactingSince: compactingSince)
                    : Self.claudeEvidence(objects, compactingSince: compactingSince) else {
                continue
            }

            if exactProcessID == nil { newestByDirectory[cwd] = candidate.modifiedAt }
            results.append(
                TranscriptActivityRecord(
                    session: AgentSessionActivity(
                        id: metadata.sessionID,
                        kind: kind,
                        state: evidence.state,
                        updatedAt: evidence.timestamp ?? candidate.modifiedAt,
                        projectName: projectName(for: cwd),
                        processID: processID,
                        source: .transcript,
                        detail: evidence.state == .working ? AgentDetailParser.consume(objects, kind: kind) : nil,
                        sessionTitle: SessionTitle.consume(objects, kind: kind)
                    ),
                    workingDirectory: cwd,
                    transcriptPath: candidate.url.standardizedFileURL.path
                )
            )
        }

        return results
    }

    private func processID(
        for transcript: URL,
        sessionID: String,
        cwd: String,
        processes: [DetectedAgentProcess],
        allowDirectoryFallback: Bool = true
    ) -> Int32? {
        let transcriptPath = transcript.standardizedFileURL.path
        let openFileMatches = processes.filter { process in
            process.openTranscriptPaths.contains {
                URL(fileURLWithPath: $0).standardizedFileURL.path == transcriptPath
            }
        }
        if openFileMatches.count == 1 { return openFileMatches[0].id }

        let hintedMatches = processes.filter { $0.sessionIDHint == sessionID }
        if hintedMatches.count == 1 { return hintedMatches[0].id }

        guard allowDirectoryFallback else { return nil }
        let cwdMatches = processes.filter {
            normalizedPath($0.workingDirectory) == cwd
        }
        guard cwdMatches.count == 1 else { return nil }

        let process = cwdMatches[0]
        if let sessionIDHint = process.sessionIDHint {
            return sessionIDHint == sessionID ? process.id : nil
        }
        guard process.openTranscriptPaths.isEmpty else { return nil }
        return process.id
    }

    public static func classifyCodexLog(_ text: String) -> AgentActivity? {
        codexEvidence(text)?.state
    }

    static func codexEvidence(
        _ text: String,
        previousState: AgentActivity? = nil
    ) -> TranscriptActivityEvidence? {
        var acceptsWorkAfterBoundary = false
        return codexEvidence(
            text,
            previousState: previousState,
            acceptsWorkAfterBoundary: &acceptsWorkAfterBoundary
        )
    }

    static func codexEvidence(
        _ text: String,
        previousState: AgentActivity?,
        acceptsWorkAfterBoundary: inout Bool
    ) -> TranscriptActivityEvidence? {
        codexEvidence(JSONObjects.lines(in: text), previousState: previousState,
                      acceptsWorkAfterBoundary: &acceptsWorkAfterBoundary)
    }

    static func codexEvidence(
        _ objects: [[String: Any]],
        previousState: AgentActivity?,
        acceptsWorkAfterBoundary: inout Bool,
        compactingSince: Date? = nil
    ) -> TranscriptActivityEvidence? {
        var state: AgentActivity?
        var timestamp: String?

        for object in objects {
            var eventState: AgentActivity?
            let type = object["type"] as? String
            let payload = object["payload"] as? [String: Any]
            let payloadType = payload?["type"] as? String

            if type == "turn_context" {
                // Compaction and automatic continuations can begin a new
                // agent turn without another task_started/user record. Arm
                // only the next real work item; the boundary alone is idle.
                acceptsWorkAfterBoundary = true
            }

            if type == "event_msg" {
                if payloadType == "task_started" {
                    eventState = .working
                } else if payloadType == "task_complete" || payloadType == "turn_aborted" {
                    eventState = .idle
                }
            }

            if type == "response_item", payloadType == "message" {
                let role = payload?["role"] as? String
                let phase = payload?["phase"] as? String
                if role == "user" {
                    eventState = .working
                } else if role == "assistant", phase == "final_answer",
                          !isCompactionSummary(object, since: compactingSince) {
                    eventState = .idle
                }
            }
            if type == "response_item", eventState == nil,
               acceptsWorkAfterBoundary || (state ?? previousState) != .idle {
                // A long task may have pushed task_started outside the bounded
                // window. Actual reasoning/tool work still proves activity,
                // including after a new turn_context. Without that boundary,
                // late outputs cannot reopen a terminal task.
                if ["reasoning", "function_call", "function_call_output",
                    "custom_tool_call", "custom_tool_call_output"].contains(payloadType ?? "")
                    || (payloadType == "message"
                        && payload?["role"] as? String == "assistant"
                        && payload?["phase"] as? String == "commentary") {
                    eventState = .working
                }
            }
            if let eventState {
                state = eventState
                timestamp = object["timestamp"] as? String
                acceptsWorkAfterBoundary = false
            }
        }

        return state.map { TranscriptActivityEvidence(state: $0, timestamp: timestamp) }
    }

    public static func classifyClaudeLog(_ text: String) -> AgentActivity? {
        claudeEvidence(text)?.state
    }

    static func claudeEvidence(_ text: String) -> TranscriptActivityEvidence? {
        claudeEvidence(JSONObjects.lines(in: text))
    }

    static func claudeEvidence(_ objects: [[String: Any]], compactingSince: Date? = nil) -> TranscriptActivityEvidence? {
        var state: AgentActivity?
        var timestamp: String?

        for object in objects {
            var eventState: AgentActivity?
            let type = object["type"] as? String
            if type == "user" {
                eventState = .working
            } else if type == "assistant",
                      let message = object["message"] as? [String: Any],
                      let stopReason = message["stop_reason"] as? String {
                if stopReason == "end_turn", !isCompactionSummary(object, since: compactingSince) {
                    eventState = .idle
                } else if stopReason == "tool_use" {
                    eventState = .working
                }
            }
            if let eventState {
                state = eventState
                timestamp = object["timestamp"] as? String
            }
        }

        return state.map { TranscriptActivityEvidence(state: $0, timestamp: timestamp) }
    }

    private static func isCompactionSummary(_ object: [String: Any], since: Date?) -> Bool {
        guard let since else { return false }
        // PreCompact proves that the final assistant message belongs to the
        // summarizer, not the user turn. Explicit task_complete/turn_aborted
        // and Stop/Interrupt still terminate normally. Never suppress history.
        guard let timestamp = TranscriptActivityEvidence(
            state: .idle, timestamp: object["timestamp"] as? String
        ).timestamp else { return false }
        return timestamp >= since
    }

    private func metadata(for url: URL, kind: AgentKind) -> (sessionID: String, cwd: String)? {
        guard let head = readHead(url) else { return nil }

        for object in JSONObjects.lines(in: head) {
            switch kind {
            case .codex:
                guard object["type"] as? String == "session_meta",
                      let payload = object["payload"] as? [String: Any],
                      let sessionID = payload["id"] as? String,
                      let cwd = payload["cwd"] as? String else { continue }
                return (sessionID, cwd)
            case .claude:
                guard let sessionID = object["sessionId"] as? String,
                      let cwd = object["cwd"] as? String else { continue }
                return (sessionID, cwd)
            }
        }

        return nil
    }

    private func recentJSONLFiles(
        at root: URL,
        limit: Int,
        sessionIDs: Set<String>
    ) -> [(url: URL, modifiedAt: Date)] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let date = values.contentModificationDate else { continue }
            result.append((url, date))
        }

        let sorted = result.sorted { $0.1 > $1.1 }
        let bound = sorted.dropFirst(limit).filter { url, _ in
            let name = url.deletingPathExtension().lastPathComponent
            return sessionIDs.contains(name)
                || (name.hasPrefix("rollout-") && sessionIDs.contains { name.hasSuffix("-" + $0) })
        }
        return Array(sorted.prefix(limit)) + bound
    }

    private func readHead(_ url: URL, limit: Int = 128 * 1_024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = try? handle.read(upToCount: limit)
        // The byte limit may split a later UTF-8 character. Preserve complete
        // earlier JSON lines instead of rejecting the entire metadata window.
        return data.map { String(decoding: $0, as: UTF8.self) }
    }

    private func readTail(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let size = try? handle.seekToEnd() else { return nil }
        defer { try? handle.close() }

        let offset = size > UInt64(tailLimit) ? size - UInt64(tailLimit) : 0
        try? handle.seek(toOffset: offset)
        guard var data = try? handle.read(upToCount: Int(size - offset)) else { return nil }

        // Drop the partial first line BEFORE UTF-8 decoding: the first byte can
        // be a continuation byte of a Cyrillic character in a large transcript.
        if offset > 0 {
            guard let newline = data.firstIndex(of: 0x0A) else { return nil }
            data = Data(data[data.index(after: newline)...])
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func normalizedPath(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func projectName(for path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

enum JSONObjects {
    static func lines(in text: String) -> [[String: Any]] {
        text.split(whereSeparator: \Character.isNewline).compactMap { line in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return object
        }
    }
}
