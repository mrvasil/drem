import Foundation

/// Neither source permanently wins. Compare the time of the actual activity
/// event, not a transcript's last file write (which may just be token accounting).
public enum AgentActivityEvidence {
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
