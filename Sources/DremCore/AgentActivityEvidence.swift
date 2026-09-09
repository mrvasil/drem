import Foundation

/// Neither source permanently wins. Compare the time of the actual activity
/// event, not a transcript's last file write (which may just be token accounting).
public enum AgentActivityEvidence {
    public static func forProcessLifetime(
        _ session: AgentSessionActivity,
        startedAt: Date?
    ) -> AgentSessionActivity {
        guard session.state == .working, let startedAt,
              session.updatedAt.timeIntervalSince1970 < floor(startedAt.timeIntervalSince1970) else {
            return session
        }
        // Resuming a transcript does not resume its historical work. Hooks use
        // whole seconds, so accept evidence in the process's first second.
        return AgentSessionActivity(
            id: session.id, kind: session.kind, state: .idle, updatedAt: startedAt,
            projectName: session.projectName, processID: session.processID, source: session.source
        )
    }

    public static func merge(
        hooks: [AgentSessionActivity],
        transcripts: [AgentSessionActivity]
    ) -> [AgentSessionActivity] {
        var bySession: [String: AgentSessionActivity] = [:]
        for session in transcripts + hooks {
            let key = session.kind.rawValue + ":" + session.id
            if let previous = bySession[key], previous.updatedAt > session.updatedAt { continue }
            bySession[key] = session
        }
        return bySession.values.sorted { $0.updatedAt > $1.updatedAt }
    }
}
