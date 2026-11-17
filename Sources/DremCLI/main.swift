import DremCore
import Foundation

do {
    // Use the same hook/transcript reconciliation as the menu-bar app.
    let live = try await LiveActivityEngine().bootstrap().snapshot
    // Keep the diagnostic CLI free of newly introduced public chat excerpts.
    // They are presentation-only and must not leak into existing issue scripts.
    let snapshot = AgentSnapshot(capturedAt: live.capturedAt, statuses: live.statuses.map { status in
        AgentStatus(kind: status.kind, state: status.state, runningProcessCount: status.runningProcessCount,
            sessions: status.sessions.map { session in
                AgentSessionActivity(id: session.id, kind: session.kind, state: session.state,
                    updatedAt: session.updatedAt, projectName: session.projectName,
                    processID: session.processID, source: session.source)
            })
    })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(snapshot)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("dremctl: \(error.localizedDescription)\n".utf8))
    exit(1)
}
