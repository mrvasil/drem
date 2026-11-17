import Foundation

public struct HookInput: Decodable, Sendable {
    public let sessionID: String
    public let cwd: String
    public let eventName: String
    public let turnID: String?
    public let source: String?
    public let trigger: String?
    public let sessionTitle: String?
    public let notificationType: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd
        case eventName = "hook_event_name"
        case turnID = "turn_id"
        case source, trigger
        case sessionTitle = "session_title"
        case notificationType = "notification_type"
    }
}

public struct HookStateRecord: Codable, Sendable {
    public let sessionID: String
    public let kind: AgentKind
    public let state: AgentActivity
    public let updatedAt: Date
    public let cwd: String
    public let processID: Int32?
    public let eventName: String
    /// State to restore after compaction. Optional for old on-disk records.
    public let compactionResumeState: AgentActivity?
    public let sessionTitle: String?
    public var attention: AgentAttention? = nil
    public var attentionUpdatedAt: Date? = nil

    public var compactionStartedAt: Date? {
        eventName == "PreCompact" && state == .working ? updatedAt : nil
    }

    public var detail: AgentActivityDetail? {
        guard state == .working else { return nil }
        if let compactionStartedAt { return AgentActivityDetail(action: .compacting, confirmedAt: compactionStartedAt) }
        guard let attention, let attentionUpdatedAt else { return nil }
        var detail = AgentActivityDetail(confirmedAt: attentionUpdatedAt, attention: attention)
        detail.attentionUpdatedAt = attentionUpdatedAt
        return detail
    }
}

public struct HookStateStore: Sendable {
    private let stateDirectory: URL
    private let legacyStateDirectory: URL
    private var fileManager: FileManager { .default }

    public var directoryURL: URL { stateDirectory }
    public var observedDirectoryURLs: [URL] { [stateDirectory, legacyStateDirectory] }

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        stateDirectory = homeDirectory
            .appendingPathComponent("Library/Application Support/drem/state", isDirectory: true)
        legacyStateDirectory = homeDirectory
            .appendingPathComponent("Library/Application Support/AgentWatch/state", isDirectory: true)
    }

    public static func activity(for eventName: String) -> AgentActivity? {
        switch eventName {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PreCompact":
            return .working
        case "SessionStart", "Stop", "StopFailure", "Interrupt":
            return .idle
        case "SessionEnd":
            return .offline
        default:
            return nil
        }
    }

    public func record(input: HookInput, kind: AgentKind, processID: Int32?, now: Date = Date()) throws {
        let file = stateFile(kind: kind, sessionID: input.sessionID)
        let previous = readRecord(at: file)
        var resumeState: AgentActivity?
        let activity: AgentActivity
        let permission = kind == .claude && input.eventName == "Notification" && input.notificationType == "permission_prompt"
        if permission {
            // Presentation evidence cannot start a turn or extend its lifetime.
            guard let previous, previous.state == .working else { return }
            activity = previous.state
        } else if input.eventName == "PreCompact" || input.eventName == "PostCompact" {
            // Manual /compact returns to the prompt; automatic compaction
            // continues the running task. Neither requires a new user prompt.
            resumeState = input.trigger == "manual" ? .idle
                : input.trigger == "auto" ? .working
                : previous?.compactionResumeState ?? previous?.state ?? .idle
            activity = input.eventName == "PreCompact" ? .working : resumeState!
        } else if input.eventName == "SessionStart", input.source == "compact" {
            // Older clients may lack PostCompact. A continuation is not a
            // fresh idle session. With no compact hook, leave evidence alone.
            guard let previous = readRecord(at: file),
                  let priorResume = previous.compactionResumeState else { return }
            resumeState = priorResume
            activity = priorResume
        } else {
            guard let value = Self.activity(for: input.eventName) else { return }
            activity = value
        }
        try ensureDirectory()

        if activity == .offline {
            removeSession(kind: kind, sessionID: input.sessionID)
            return
        }

        var record = HookStateRecord(
            sessionID: input.sessionID,
            kind: kind,
            state: activity,
            updatedAt: permission ? previous!.updatedAt : now,
            cwd: input.cwd,
            processID: processID,
            eventName: input.eventName,
            compactionResumeState: resumeState,
            sessionTitle: SessionTitle.clean(input.sessionTitle) ?? previous?.sessionTitle
        )
        if permission {
            record.attention = .permission
            record.attentionUpdatedAt = now
        }
        let encoder = JSONEncoder()
        // A summary and PostCompact can be milliseconds apart. Whole-second
        // hook timestamps allow the earlier summary to win the merge.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var value = encoder.singleValueContainer()
            try value.encode(ActivityTimestamp.string(date))
        }
        let data = try encoder.encode(record)
        try data.write(to: file, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    public func readValid(processes: [DetectedAgentProcess]) -> [AgentSessionActivity] {
        let liveProcesses = Dictionary(uniqueKeysWithValues: processes.map { ($0.id, $0) })
        return readAll().compactMap { record in
            guard let processID = record.processID,
                  let process = liveProcesses[processID],
                  process.kind == record.kind,
                  process.workingDirectory.map({ normalizedPath($0) }) == normalizedPath(record.cwd) else {
                return nil
            }

            return AgentSessionActivity(
                id: record.sessionID,
                kind: record.kind,
                state: record.state,
                updatedAt: record.updatedAt,
                projectName: URL(fileURLWithPath: record.cwd).lastPathComponent,
                processID: processID,
                source: .hook,
                detail: record.detail,
                sessionTitle: record.sessionTitle
            )
        }
    }

    public func readAll() -> [HookStateRecord] {
        // Old running agent sessions may still use their cached pre-drem hook.
        let files = observedDirectoryURLs.flatMap { directory in
            (try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []
        }

        let records: [HookStateRecord] = files.compactMap { file in
            guard file.pathExtension == "json" else { return nil }
            return readRecord(at: file)
        }
        var latest: [String: HookStateRecord] = [:]
        for record in records {
            let key = "\(record.kind.rawValue):\(record.sessionID)"
            if let previous = latest[key], previous.updatedAt >= record.updatedAt { continue }
            latest[key] = record
        }
        return latest.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func removeSession(kind: AgentKind, sessionID: String) {
        let name = stateFile(kind: kind, sessionID: sessionID).lastPathComponent
        for directory in [stateDirectory, legacyStateDirectory] {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    func readRecord(at file: URL) -> HookStateRecord? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            let string = try value.decode(String.self)
            guard let date = TranscriptActivityEvidence(state: .idle, timestamp: string).timestamp else {
                throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid hook timestamp")
            }
            return date
        }
        return try? decoder.decode(HookStateRecord.self, from: data)
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDirectory.path)
    }

    private func stateFile(kind: AgentKind, sessionID: String) -> URL {
        let safeID = sessionID.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return stateDirectory.appendingPathComponent("\(kind.rawValue)-\(safeID).json")
    }

    private func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
