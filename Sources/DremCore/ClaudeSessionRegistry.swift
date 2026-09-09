import Foundation

/// Claude closes its transcript between writes. Its small per-PID registry
/// supplies identity without guessing which of several same-cwd agents owns it.
struct ClaudeSessionRegistry: Sendable {
    private struct Record: Decodable {
        let pid: Int32
        let sessionId: String
        let procStart: String
        let pidDomain: String?
    }

    let directoryURL: URL

    init(homeDirectory: URL) {
        directoryURL = homeDirectory.appendingPathComponent(".claude/sessions", isDirectory: true)
    }

    func applying(to processes: [DetectedAgentProcess]) -> [DetectedAgentProcess] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"

        return processes.map { process in
            guard process.kind == .claude, let startedAt = process.startedAt,
                  let record = read(processID: process.id), record.pid == process.id,
                  record.pidDomain == nil || record.pidDomain == "darwin",
                  UUID(uuidString: record.sessionId) != nil,
                  let registeredStart = formatter.date(from: record.procStart),
                  floor(registeredStart.timeIntervalSince1970) == floor(startedAt.timeIntervalSince1970) else {
                return process
            }
            // procStart is checked against the kernel, not merely PID existence:
            // a registry file left after a crash must not bind a reused PID.
            return DetectedAgentProcess(
                id: process.id, parentPID: process.parentPID, kind: process.kind,
                elapsed: process.elapsed, state: process.state, command: process.command,
                workingDirectory: process.workingDirectory, openTranscriptPaths: process.openTranscriptPaths,
                sessionIDHint: record.sessionId, startedAt: process.startedAt
            )
        }
    }

    func isRegistryEvent(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return url.path == directoryURL.standardizedFileURL.path
            || url.deletingLastPathComponent().path == directoryURL.standardizedFileURL.path
    }

    func needsDiscovery(for paths: [String], processes: [DetectedAgentProcess]) -> Bool {
        let events = paths.filter(isRegistryEvent)
        guard !events.isEmpty else { return false }
        let registered = applying(to: processes)
        if registered != processes { return true }
        return events.contains { path in
            let url = URL(fileURLWithPath: path)
            if url.standardizedFileURL.path == directoryURL.standardizedFileURL.path { return true }
            guard url.pathExtension == "json", let pid = Int32(url.deletingPathExtension().lastPathComponent) else {
                return false
            }
            // Status updates for a known identity need no ps/lsof. New/deleted
            // registrations do, because the process set or binding can change.
            return !processes.contains { $0.kind == .claude && $0.id == pid }
                || !FileManager.default.fileExists(atPath: path)
        }
    }

    private func read(processID: Int32) -> Record? {
        let url = directoryURL.appendingPathComponent("\(processID).json")
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 65_537), data.count <= 65_536 else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }
}
