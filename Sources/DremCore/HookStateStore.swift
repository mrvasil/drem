import Foundation

public struct HookInput: Decodable, Sendable {
    public let sessionID: String
    public let cwd: String
    public let eventName: String
    public let turnID: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case cwd
        case eventName = "hook_event_name"
        case turnID = "turn_id"
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
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure":
            return .working
        case "SessionStart", "Stop", "StopFailure", "Interrupt":
            return .idle
        case "SessionEnd":
            return .offline
        default:
            return nil
        }
    }

    public func record(input: HookInput, kind: AgentKind, processID: Int32?) throws {
        guard let activity = Self.activity(for: input.eventName) else { return }
        try ensureDirectory()
        let file = stateFile(kind: kind, sessionID: input.sessionID)

        if activity == .offline {
            removeSession(kind: kind, sessionID: input.sessionID)
            return
        }

        let record = HookStateRecord(
            sessionID: input.sessionID,
            kind: kind,
            state: activity,
            updatedAt: Date(),
            cwd: input.cwd,
            processID: processID,
            eventName: input.eventName
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
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
                source: .hook
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

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let records: [HookStateRecord] = files.compactMap { file in
            guard file.pathExtension == "json",
                  let data = try? Data(contentsOf: file) else { return nil }
            return try? decoder.decode(HookStateRecord.self, from: data)
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
