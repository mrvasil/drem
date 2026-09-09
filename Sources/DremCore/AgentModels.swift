import Foundation

public enum AgentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex
    case claude

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        }
    }

    public var systemImage: String {
        switch self {
        case .codex: return "terminal.fill"
        case .claude: return "sparkles"
        }
    }
}

public enum AgentActivity: String, Codable, Sendable {
    case working
    case idle
    case offline
}

public enum ActivitySource: String, Codable, Sendable {
    case hook
    case transcript
    case process
}

public struct DetectedAgentProcess: Codable, Identifiable, Equatable, Sendable {
    public let id: Int32
    public let parentPID: Int32
    public let kind: AgentKind
    public let elapsed: String
    public let state: String
    public let command: String
    public let workingDirectory: String?
    public let openTranscriptPaths: [String]
    public let sessionIDHint: String?
    public let startedAt: Date?

    public init(
        id: Int32,
        parentPID: Int32,
        kind: AgentKind,
        elapsed: String,
        state: String,
        command: String,
        workingDirectory: String? = nil,
        openTranscriptPaths: [String] = [],
        sessionIDHint: String? = nil,
        startedAt: Date? = nil
    ) {
        self.id = id
        self.parentPID = parentPID
        self.kind = kind
        self.elapsed = elapsed
        self.state = state
        self.command = command
        self.workingDirectory = workingDirectory
        self.openTranscriptPaths = openTranscriptPaths
        self.sessionIDHint = sessionIDHint
        self.startedAt = startedAt
    }
}

public struct AgentSessionActivity: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: AgentKind
    public let state: AgentActivity
    public let updatedAt: Date
    public let projectName: String?
    public let processID: Int32?
    public let source: ActivitySource

    public init(
        id: String,
        kind: AgentKind,
        state: AgentActivity,
        updatedAt: Date,
        projectName: String?,
        processID: Int32?,
        source: ActivitySource
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.updatedAt = updatedAt
        self.projectName = projectName
        self.processID = processID
        self.source = source
    }
}

public struct AgentStatus: Codable, Identifiable, Equatable, Sendable {
    public var id: AgentKind { kind }
    public let kind: AgentKind
    public let state: AgentActivity
    public let runningProcessCount: Int
    public let sessions: [AgentSessionActivity]

    public init(
        kind: AgentKind,
        state: AgentActivity,
        runningProcessCount: Int,
        sessions: [AgentSessionActivity]
    ) {
        self.kind = kind
        self.state = state
        self.runningProcessCount = runningProcessCount
        self.sessions = sessions
    }

    public var workingSessions: [AgentSessionActivity] {
        sessions.filter { $0.state == .working }
    }
}

public struct AgentSnapshot: Codable, Equatable, Sendable {
    public let capturedAt: Date
    public let statuses: [AgentStatus]

    public init(capturedAt: Date = Date(), statuses: [AgentStatus]) {
        self.capturedAt = capturedAt
        self.statuses = statuses
    }

    public static let empty = AgentSnapshot(
        capturedAt: .distantPast,
        statuses: AgentKind.allCases.map {
            AgentStatus(kind: $0, state: .offline, runningProcessCount: 0, sessions: [])
        }
    )

    public func status(for kind: AgentKind) -> AgentStatus {
        statuses.first { $0.kind == kind }
            ?? AgentStatus(kind: kind, state: .offline, runningProcessCount: 0, sessions: [])
    }

    public var workingCount: Int {
        statuses.reduce(0) { $0 + $1.workingSessions.count }
    }

    public var hasWorkingAgent: Bool {
        statuses.contains { $0.state == .working }
    }
}

public enum ScannerError: LocalizedError {
    case launchFailed(String)
    case commandFailed(Int32, String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            return "Не удалось запустить ps: \(message)"
        case .commandFailed(let code, let message):
            return "ps завершился с кодом \(code): \(message)"
        }
    }
}
