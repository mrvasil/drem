import Foundation

public struct ProcessScanner: Sendable {
    private struct OpenFileDetails {
        var workingDirectory: String?
        var transcriptPaths = Set<String>()
    }

    public init() {}

    public func scan() throws -> [DetectedAgentProcess] {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,etime=,stat=,comm=,args="]
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw ScannerError.launchFailed(error.localizedDescription)
        }

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
            throw ScannerError.commandFailed(process.terminationStatus, message)
        }

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let detected = output
            .split(whereSeparator: \Character.isNewline)
            .compactMap(Self.parse(line:))
            .filter { $0.id != ownPID }

        let openFiles = openFileDetails(for: detected.map(\.id))
        return detected
            .map { item in
                let details = openFiles[item.id]
                return DetectedAgentProcess(
                    id: item.id,
                    parentPID: item.parentPID,
                    kind: item.kind,
                    elapsed: item.elapsed,
                    state: item.state,
                    command: item.command,
                    workingDirectory: details?.workingDirectory,
                    openTranscriptPaths: details.map { Array($0.transcriptPaths).sorted() } ?? [],
                    sessionIDHint: item.sessionIDHint
                )
            }
            .sorted { lhs, rhs in
                if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
                return lhs.id < rhs.id
            }
    }

    public static func parse(line: Substring) -> DetectedAgentProcess? {
        let fields = line.split(
            maxSplits: 5,
            omittingEmptySubsequences: true,
            whereSeparator: { $0 == " " || $0 == "\t" }
        )

        guard fields.count == 6,
              let pid = Int32(fields[0]),
              let parentPID = Int32(fields[1]) else {
            return nil
        }

        let elapsed = String(fields[2])
        let state = String(fields[3])
        let command = String(fields[4])
        let arguments = String(fields[5])

        guard let kind = classify(command: command, arguments: arguments) else {
            return nil
        }

        return DetectedAgentProcess(
            id: pid,
            parentPID: parentPID,
            kind: kind,
            elapsed: elapsed,
            state: state,
            command: command,
            sessionIDHint: sessionIDHint(in: arguments)
        )
    }

    public static func classify(command: String, arguments: String) -> AgentKind? {
        let executable = URL(fileURLWithPath: command).lastPathComponent.lowercased()
        let normalizedArguments = arguments.lowercased()

        if executable == "codex" {
            return .codex
        }

        if executable == "claude" {
            return .claude
        }

        if normalizedArguments.hasPrefix("/applications/chatgpt.app/contents/resources/codex ") {
            return .codex
        }

        let isJavaScriptRuntime = ["node", "nodejs", "bun", "deno"].contains(executable)
        guard isJavaScriptRuntime else { return nil }

        if normalizedArguments.contains("node_modules/@openai/codex") ||
            normalizedArguments.contains("/@openai/codex/bin/codex") {
            return .codex
        }

        if normalizedArguments.contains("node_modules/@anthropic-ai/claude-code") ||
            normalizedArguments.contains("/@anthropic-ai/claude-code/cli.js") {
            return .claude
        }

        return nil
    }

    public static func sessionIDHint(in arguments: String) -> String? {
        let fields = arguments.split(whereSeparator: { $0 == " " || $0 == "\t" })
        for (index, field) in fields.enumerated()
        where field == "resume" || field == "--resume" || field == "--session-id" {
            let valueIndex = fields.index(after: index)
            guard valueIndex < fields.endIndex else { continue }
            let value = String(fields[valueIndex])
            if !value.hasPrefix("-") { return value }
        }
        return nil
    }

    private func openFileDetails(for processIDs: [Int32]) -> [Int32: OpenFileDetails] {
        guard !processIDs.isEmpty else { return [:] }

        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-n", "-P", "-Fpcfn", "-p", processIDs.map(String.init).joined(separator: ",")]
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        guard (try? process.run()) != nil else { return [:] }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        var currentPID: Int32?
        var currentDescriptor: String?
        var result: [Int32: OpenFileDetails] = [:]

        for line in output.split(whereSeparator: \Character.isNewline) {
            guard let prefix = line.first else { continue }
            let value = line.dropFirst()
            if prefix == "p" {
                currentPID = Int32(value)
                if let currentPID, result[currentPID] == nil {
                    result[currentPID] = OpenFileDetails()
                }
            } else if prefix == "f" {
                currentDescriptor = String(value)
            } else if prefix == "n", let currentPID {
                let path = String(value)
                if currentDescriptor == "cwd" {
                    result[currentPID, default: OpenFileDetails()].workingDirectory = path
                } else if isAgentTranscript(path) {
                    result[currentPID, default: OpenFileDetails()].transcriptPaths.insert(
                        URL(fileURLWithPath: path).standardizedFileURL.path
                    )
                }
            }
        }

        return result
    }

    private func isAgentTranscript(_ path: String) -> Bool {
        guard path.hasSuffix(".jsonl") else { return false }
        return path.contains("/.codex/sessions/") || path.contains("/.claude/projects/")
    }
}
