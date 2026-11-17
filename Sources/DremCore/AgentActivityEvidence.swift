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
        // Resuming a transcript does not resume its historical work. Legacy hooks use
        // whole seconds, so accept evidence in the process's first second.
        return AgentSessionActivity(
            id: session.id, kind: session.kind, state: .idle, updatedAt: startedAt,
            projectName: session.projectName, processID: session.processID, source: session.source,
            workingDirectory: session.workingDirectory, sessionTitle: session.sessionTitle
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
        return bySession.values.map { session in
            // A newer working hook wins activity, but need not erase detail
            // from the same turn. Never revive detail across a newer start.
            guard session.state == .working, session.detail == nil,
                  let detail = transcripts.first(where: {
                      $0.kind == session.kind && $0.id == session.id && $0.state == .working
                  })?.detail,
                  let confirmed = detail.confirmedAt,
                  confirmed.timeIntervalSince1970 >= floor(session.updatedAt.timeIntervalSince1970) else {
                return session
            }
            return AgentSessionActivity(id: session.id, kind: session.kind, state: session.state,
                updatedAt: session.updatedAt, projectName: session.projectName,
                processID: session.processID, source: session.source, detail: detail,
                workingDirectory: session.workingDirectory, sessionTitle: session.sessionTitle)
        }.map { session in
            mergeAttention(session, hooks: hooks, transcripts: transcripts)
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func mergeAttention(_ session: AgentSessionActivity,
                                       hooks: [AgentSessionActivity],
                                       transcripts: [AgentSessionActivity]) -> AgentSessionActivity {
        guard session.state == .working else { return session }
        let transcript = transcripts.first { $0.kind == session.kind && $0.id == session.id }
        let hook = hooks.first { $0.kind == session.kind && $0.id == session.id }
        let transcriptDetail = transcript?.state == .working ? transcript?.detail : nil
        let hookDetail = hook?.state == .working ? hook?.detail : nil
        var attention = transcriptDetail?.attention
        var evidenceAt = transcriptDetail?.attentionUpdatedAt
        let continuation = transcriptDetail?.attentionContinuationAt
        if let hookAt = hookDetail?.attentionUpdatedAt,
           (attention == nil || hookAt > (evidenceAt ?? .distantPast)),
           hookAt > (continuation ?? .distantPast) {
            attention = hookDetail?.attention
            evidenceAt = hookAt
        }
        // A lifecycle hook can close an old wait without any further transcript
        // write. Compare its activity time, not the notification receipt time.
        if let hook, hookDetail?.attention == nil,
           hook.updatedAt > (evidenceAt ?? .distantPast) {
            attention = nil
        }
        var detail = session.detail
        if detail == nil, attention != nil { detail = AgentActivityDetail() }
        detail?.attention = attention
        detail?.attentionUpdatedAt = evidenceAt
        return AgentSessionActivity(id: session.id, kind: session.kind, state: session.state,
            updatedAt: session.updatedAt, projectName: session.projectName, processID: session.processID,
            source: session.source, detail: detail,
            workingDirectory: session.workingDirectory, sessionTitle: session.sessionTitle)
    }

    public static func applyingActiveCodexGoals(
        _ sessions: [AgentSessionActivity],
        activeGoals: [String: Date]
    ) -> [AgentSessionActivity] {
        sessions.map { session in
            guard session.kind == .codex, let goalUpdatedAt = activeGoals[session.id] else {
                return session
            }
            return AgentSessionActivity(
                id: session.id,
                kind: session.kind,
                state: .working,
                updatedAt: max(session.updatedAt, goalUpdatedAt),
                projectName: session.projectName,
                processID: session.processID,
                source: .goal,
                detail: session.state == .working ? session.detail : nil,
                workingDirectory: session.workingDirectory, sessionTitle: session.sessionTitle
            )
        }.sorted { $0.updatedAt > $1.updatedAt }
    }
}
