import Foundation

public struct IncrementalTranscriptResult: Sendable {
    public let session: AgentSessionActivity
    public let workingDirectory: String
    public let bytesRead: Int
    public let wasIncremental: Bool
}

public final class IncrementalTranscriptScanner: @unchecked Sendable {
    private struct Metadata {
        let sessionID: String
        let cwd: String
    }

    private struct Cursor {
        var offset: UInt64
        var remainder: Data
        let metadata: Metadata
        var state: AgentActivity
        var activityAt: Date
    }

    private let tailLimit: Int
    private var cursors: [String: Cursor] = [:]
    private let lock = NSLock()

    public init(tailLimit: Int = 4 * 1_024 * 1_024) {
        self.tailLimit = tailLimit
    }

    public func consume(url: URL, kind: AgentKind) -> IncrementalTranscriptResult? {
        lock.lock()
        defer { lock.unlock() }

        let path = url.standardizedFileURL.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let sizeNumber = attributes[.size] as? NSNumber else {
            cursors.removeValue(forKey: path)
            return nil
        }

        let size = sizeNumber.uint64Value
        let modifiedAt = attributes[.modificationDate] as? Date ?? Date()

        if var cursor = cursors[path], size >= cursor.offset {
            if size == cursor.offset {
                return makeResult(
                    metadata: cursor.metadata, kind: kind, state: cursor.state,
                    updatedAt: cursor.activityAt, bytesRead: 0, wasIncremental: true
                )
            }
            guard let appended = read(url: url, from: cursor.offset, count: size - cursor.offset) else { return nil }
            let bytesRead = appended.count
            cursor.offset += UInt64(bytesRead)

            let combined = cursor.remainder + appended
            let split = completeJSONLines(in: combined)
            cursor.remainder = split.remainder

            if !split.text.isEmpty,
               let evidence = classify(split.text, kind: kind, previousState: cursor.state) {
                cursor.state = evidence.state
                cursor.activityAt = evidence.timestamp ?? modifiedAt
            }
            cursors[path] = cursor

            return makeResult(
                metadata: cursor.metadata,
                kind: kind,
                state: cursor.state,
                updatedAt: cursor.activityAt,
                bytesRead: bytesRead,
                wasIncremental: true
            )
        }

        guard let metadata = metadata(for: url, kind: kind),
              let initial = readTail(url: url, size: size),
              let evidence = classify(initial.text, kind: kind) else {
            return nil
        }

        cursors[path] = Cursor(
            offset: size,
            remainder: initial.remainder,
            metadata: metadata,
            state: evidence.state,
            activityAt: evidence.timestamp ?? modifiedAt
        )

        return makeResult(
            metadata: metadata,
            kind: kind,
            state: evidence.state,
            updatedAt: evidence.timestamp ?? modifiedAt,
            bytesRead: initial.bytesRead,
            wasIncremental: false
        )
    }

    public func forget(url: URL) {
        lock.lock()
        cursors.removeValue(forKey: url.standardizedFileURL.path)
        lock.unlock()
    }

    private func makeResult(
        metadata: Metadata,
        kind: AgentKind,
        state: AgentActivity,
        updatedAt: Date,
        bytesRead: Int,
        wasIncremental: Bool
    ) -> IncrementalTranscriptResult {
        IncrementalTranscriptResult(
            session: AgentSessionActivity(
                id: metadata.sessionID,
                kind: kind,
                state: state,
                updatedAt: updatedAt,
                projectName: URL(fileURLWithPath: metadata.cwd).lastPathComponent,
                processID: nil,
                source: .transcript
            ),
            workingDirectory: URL(fileURLWithPath: metadata.cwd).standardizedFileURL.path,
            bytesRead: bytesRead,
            wasIncremental: wasIncremental
        )
    }

    private func classify(
        _ text: String,
        kind: AgentKind,
        previousState: AgentActivity? = nil
    ) -> TranscriptActivityEvidence? {
        switch kind {
        case .codex:
            return ActivityLogScanner.codexEvidence(text, previousState: previousState)
        case .claude:
            return ActivityLogScanner.claudeEvidence(text)
        }
    }

    private func metadata(for url: URL, kind: AgentKind) -> Metadata? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 128 * 1_024) else {
            return nil
        }
        let text = String(decoding: data, as: UTF8.self)

        for line in text.split(whereSeparator: \Character.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            switch kind {
            case .codex:
                guard object["type"] as? String == "session_meta",
                      let payload = object["payload"] as? [String: Any],
                      let sessionID = payload["id"] as? String,
                      let cwd = payload["cwd"] as? String else { continue }
                return Metadata(sessionID: sessionID, cwd: cwd)
            case .claude:
                guard let sessionID = object["sessionId"] as? String,
                      let cwd = object["cwd"] as? String else { continue }
                return Metadata(sessionID: sessionID, cwd: cwd)
            }
        }

        return nil
    }

    private func readTail(url: URL, size: UInt64) -> (text: String, remainder: Data, bytesRead: Int)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let limit = UInt64(tailLimit)
        let offset = size > limit ? size - limit : 0
        try? handle.seek(toOffset: offset)
        guard var data = try? handle.read(upToCount: Int(size - offset)) else { return nil }

        if offset > 0, let newline = data.firstIndex(of: 0x0A) {
            data = Data(data[data.index(after: newline)...])
        }

        let split = completeJSONLines(in: data)
        return (split.text, split.remainder, data.count)
    }

    private func read(url: URL, from offset: UInt64, count: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        // Never read past the size observed above: the writer may append more
        // concurrently, and advancing by a stale stat size would replay bytes.
        return try? handle.read(upToCount: Int(count))
    }

    private func completeJSONLines(in data: Data) -> (text: String, remainder: Data) {
        guard !data.isEmpty else { return ("", Data()) }

        if let text = String(data: data, encoding: .utf8), isCompleteJSONLines(text) {
            return (text, Data())
        }

        guard let newline = data.lastIndex(of: 0x0A) else {
            return ("", data)
        }

        let complete = Data(data[...newline])
        let remainderStart = data.index(after: newline)
        let remainder = remainderStart < data.endIndex ? Data(data[remainderStart...]) : Data()
        return (String(data: complete, encoding: .utf8) ?? "", remainder)
    }

    private func isCompleteJSONLines(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \Character.isNewline)
        guard !lines.isEmpty else { return true }
        return lines.allSatisfy { line in
            guard let data = line.data(using: .utf8) else { return false }
            return (try? JSONSerialization.jsonObject(with: data)) != nil
        }
    }
}
