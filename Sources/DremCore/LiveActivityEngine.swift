import Foundation

public struct LiveActivityState: Sendable {
    public let snapshot: AgentSnapshot
    public let processIDs: [Int32]
    public let transcriptPaths: [String]
    public let needsProcessReconciliation: Bool
}

public actor LiveActivityEngine {
    private struct SessionKey: Hashable {
        let kind: AgentKind
        let id: String
    }

    private struct TrackedSession {
        let activity: AgentSessionActivity
        let workingDirectory: String?
        let transcriptPath: String
    }

    private let homeDirectory: URL
    private let hookStore: HookStateStore
    private let incrementalScanner: IncrementalTranscriptScanner
    private var processes: [DetectedAgentProcess] = []
    private var transcriptSessions: [SessionKey: TrackedSession] = [:]
    private var knownHookSessions = Set<SessionKey>()
    private var hookProcessIDs: [SessionKey: Int32] = [:]

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
        hookStore = HookStateStore(homeDirectory: homeDirectory)
        incrementalScanner = IncrementalTranscriptScanner()
    }

    public func bootstrap() throws -> LiveActivityState {
        try reconcile()
    }

    public func reconcile() throws -> LiveActivityState {
        let processes = try ProcessScanner().scan()
        return reconcile(processes: processes)
    }

    public func reconcile(processes: [DetectedAgentProcess]) -> LiveActivityState {
        self.processes = processes
        let transcriptRecords = ActivityLogScanner(homeDirectory: homeDirectory)
            .scanTranscriptRecords(processes: processes)

        transcriptSessions = Dictionary(
            uniqueKeysWithValues: transcriptRecords.map { record in
                let session = record.session
                return (
                    SessionKey(kind: session.kind, id: session.id),
                    TrackedSession(
                        activity: session,
                        workingDirectory: record.workingDirectory,
                        transcriptPath: record.transcriptPath
                    )
                )
            }
        )
        let hookRecords = hookStore.readAll()
        knownHookSessions = Set(hookRecords.map {
            SessionKey(kind: $0.kind, id: $0.sessionID)
        })
        refreshHookProcessLinks(records: hookRecords)

        return makeState(acceptRecentUnmatched: false, needsProcessReconciliation: false)
    }

    public func handleFileEvents(_ paths: [String]) -> LiveActivityState {
        var needsReconciliation = false

        for path in Set(paths) {
            guard let kind = transcriptKind(for: path) else { continue }
            let url = URL(fileURLWithPath: path)

            guard FileManager.default.fileExists(atPath: path) else {
                incrementalScanner.forget(url: url)
                continue
            }

            guard let result = incrementalScanner.consume(url: url, kind: kind) else { continue }
            let key = SessionKey(kind: kind, id: result.session.id)
            let linkedProcessID = matchingProcessID(
                kind: kind,
                sessionID: result.session.id,
                workingDirectory: result.workingDirectory,
                transcriptPath: path
            ) ?? transcriptSessions[key]?.activity.processID
            let linkedSession = AgentSessionActivity(
                id: result.session.id,
                kind: result.session.kind,
                state: result.session.state,
                updatedAt: result.session.updatedAt,
                projectName: result.session.projectName,
                processID: linkedProcessID,
                source: result.session.source
            )
            transcriptSessions[key] = TrackedSession(
                activity: linkedSession,
                workingDirectory: result.workingDirectory,
                transcriptPath: url.standardizedFileURL.path
            )

            if !result.wasIncremental ||
                !hasMatchingProcess(
                    kind: kind,
                    workingDirectory: result.workingDirectory,
                    processID: linkedProcessID
                ) {
                needsReconciliation = true
            }
        }

        let now = Date()
        let hookRecords = hookStore.readAll()
        let hookKeys = Set(hookRecords.map { SessionKey(kind: $0.kind, id: $0.sessionID) })
        if !hookKeys.subtracting(knownHookSessions).isEmpty {
            needsReconciliation = true
        }
        knownHookSessions = hookKeys
        refreshHookProcessLinks(records: hookRecords)

        for record in hookRecords where now.timeIntervalSince(record.updatedAt) < 5 {
            if !hasMatchingProcess(
                kind: record.kind,
                workingDirectory: record.cwd,
                processID: record.processID
            ) {
                needsReconciliation = true
            }
        }

        return makeState(
            acceptRecentUnmatched: true,
            needsProcessReconciliation: needsReconciliation
        )
    }

    public func recheckWorkingTranscripts() -> LiveActivityState {
        recheckTrackedTranscripts()
    }

    /// Recheck only already-bound transcript files, including idle sessions so
    /// a missed task-start event is repaired as well as a missed task completion.
    public func recheckTrackedTranscripts() -> LiveActivityState {
        let trackedSessions = transcriptSessions

        for (key, tracked) in trackedSessions {
            let url = URL(fileURLWithPath: tracked.transcriptPath)
            guard let result = incrementalScanner.consume(url: url, kind: key.kind) else {
                continue
            }

            let linkedProcessID = matchingProcessID(
                kind: key.kind,
                sessionID: key.id,
                workingDirectory: result.workingDirectory,
                transcriptPath: tracked.transcriptPath
            ) ?? tracked.activity.processID
            let session = AgentSessionActivity(
                id: result.session.id,
                kind: result.session.kind,
                state: result.session.state,
                updatedAt: result.session.updatedAt,
                projectName: result.session.projectName,
                processID: linkedProcessID,
                source: result.session.source
            )
            transcriptSessions[key] = TrackedSession(
                activity: session,
                workingDirectory: result.workingDirectory,
                transcriptPath: tracked.transcriptPath
            )
        }

        return makeState(acceptRecentUnmatched: false, needsProcessReconciliation: false)
    }

    public func processExited(_ processID: Int32) -> LiveActivityState {
        let endedHookSessions = hookProcessIDs.compactMap { key, linkedProcessID in
            linkedProcessID == processID ? key : nil
        }
        for key in endedHookSessions {
            hookStore.removeSession(kind: key.kind, sessionID: key.id)
            hookProcessIDs.removeValue(forKey: key)
            knownHookSessions.remove(key)
        }

        processes.removeAll { $0.id == processID }
        transcriptSessions = transcriptSessions.filter { _, tracked in
            tracked.activity.processID != processID
        }
        return makeState(acceptRecentUnmatched: false, needsProcessReconciliation: false)
    }

    private func makeState(
        acceptRecentUnmatched: Bool,
        needsProcessReconciliation: Bool
    ) -> LiveActivityState {
        let now = Date()
        let freshInterval: TimeInterval = 5
        let hookRecords = hookStore.readAll()
        refreshHookProcessLinks(records: hookRecords)

        let statuses = AgentKind.allCases.map { kind in
            let kindProcesses = processes.filter { $0.kind == kind }
            let hooks = hookRecords.compactMap { record -> AgentSessionActivity? in
                guard record.kind == kind else { return nil }
                let key = SessionKey(kind: record.kind, id: record.sessionID)
                let linkedProcessID = record.processID ?? hookProcessIDs[key]
                let matches = hasMatchingProcess(
                    kind: record.kind,
                    workingDirectory: record.cwd,
                    processID: linkedProcessID
                )
                let isFresh = now.timeIntervalSince(record.updatedAt) < freshInterval
                guard matches || (acceptRecentUnmatched && isFresh) else { return nil }

                return AgentSessionActivity(
                    id: record.sessionID,
                    kind: record.kind,
                    state: record.state,
                    updatedAt: record.updatedAt,
                    projectName: URL(fileURLWithPath: record.cwd).lastPathComponent,
                    processID: linkedProcessID,
                    source: .hook
                )
            }

            let transcripts = transcriptSessions.values.compactMap { tracked -> AgentSessionActivity? in
                let session = tracked.activity
                guard session.kind == kind else { return nil }

                let matches = hasMatchingProcess(
                    kind: kind,
                    workingDirectory: tracked.workingDirectory,
                    processID: session.processID
                )
                let isFresh = now.timeIntervalSince(session.updatedAt) < freshInterval
                guard matches || (acceptRecentUnmatched && isFresh) else { return nil }
                return session
            }

            let sessions = AgentActivityEvidence.merge(hooks: hooks, transcripts: transcripts)
            let state: AgentActivity
            if kindProcesses.isEmpty && sessions.isEmpty {
                state = .offline
            } else if sessions.contains(where: { $0.state == .working }) {
                state = .working
            } else {
                state = .idle
            }

            return AgentStatus(
                kind: kind,
                state: state,
                runningProcessCount: kindProcesses.count,
                sessions: sessions
            )
        }

        return LiveActivityState(
            snapshot: AgentSnapshot(statuses: statuses),
            processIDs: processes.map(\.id),
            transcriptPaths: Array(Set(
                transcriptSessions.values.map(\.transcriptPath)
                    + processes.flatMap(\.openTranscriptPaths)
            )).sorted(),
            needsProcessReconciliation: needsProcessReconciliation
        )
    }

    private func hasMatchingProcess(
        kind: AgentKind,
        workingDirectory: String?,
        processID: Int32?
    ) -> Bool {
        let candidates = processes.filter { $0.kind == kind }
        if let processID {
            return candidates.contains { $0.id == processID }
        }

        guard let workingDirectory else { return !candidates.isEmpty }
        let normalizedDirectory = normalizedPath(workingDirectory)
        let knownDirectories = candidates.compactMap { $0.workingDirectory.map(normalizedPath) }
        return knownDirectories.isEmpty || knownDirectories.contains(normalizedDirectory)
    }

    private func matchingProcessID(
        kind: AgentKind,
        sessionID: String,
        workingDirectory: String,
        transcriptPath: String?
    ) -> Int32? {
        let candidates = processes.filter { $0.kind == kind }

        if let transcriptPath {
            let normalizedTranscript = normalizedPath(transcriptPath)
            let openFileMatches = candidates.filter { process in
                process.openTranscriptPaths.contains { normalizedPath($0) == normalizedTranscript }
            }
            if openFileMatches.count == 1 { return openFileMatches[0].id }
        }

        let hintedMatches = candidates.filter { $0.sessionIDHint == sessionID }
        if hintedMatches.count == 1 { return hintedMatches[0].id }

        let normalizedDirectory = normalizedPath(workingDirectory)
        let cwdMatches = candidates.filter {
            $0.workingDirectory.map(normalizedPath) == normalizedDirectory
        }
        guard cwdMatches.count == 1 else { return nil }

        let process = cwdMatches[0]
        if let sessionIDHint = process.sessionIDHint {
            return sessionIDHint == sessionID ? process.id : nil
        }
        return process.id
    }

    private func refreshHookProcessLinks(records: [HookStateRecord]) {
        let currentKeys = Set(records.map { SessionKey(kind: $0.kind, id: $0.sessionID) })
        hookProcessIDs = hookProcessIDs.filter { key, processID in
            currentKeys.contains(key) && processes.contains { $0.id == processID }
        }

        for record in records {
            let key = SessionKey(kind: record.kind, id: record.sessionID)
            guard hookProcessIDs[key] == nil else { continue }

            let linkedProcessID = record.processID
                ?? transcriptSessions[key]?.activity.processID
                ?? matchingProcessID(
                    kind: record.kind,
                    sessionID: record.sessionID,
                    workingDirectory: record.cwd,
                    transcriptPath: nil
                )
            if let linkedProcessID {
                hookProcessIDs[key] = linkedProcessID
            }
        }
    }

    private func transcriptKind(for path: String) -> AgentKind? {
        guard URL(fileURLWithPath: path).pathExtension == "jsonl" else { return nil }
        let normalized = normalizedPath(path)
        let codexRoot = normalizedPath(homeDirectory.appendingPathComponent(".codex/sessions").path) + "/"
        let claudeRoot = normalizedPath(homeDirectory.appendingPathComponent(".claude/projects").path) + "/"

        if normalized.hasPrefix(codexRoot) { return .codex }
        if normalized.hasPrefix(claudeRoot) { return .claude }
        return nil
    }

    private func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
