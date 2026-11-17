import AppKit
import Darwin
import DremCore
import Foundation

/// Navigation is a user action, not part of activity detection. Only kernel
/// process identity and terminal TTY/IDs are read; never argv, env or screen text.
enum TerminalNavigation {
    struct ProcessIdentity: Equatable, Sendable {
        let pid: Int32
        let parentPID: Int32
        let startedAt: Date
        let tty: String?
        var userID: uid_t = getuid()

        static func read(_ pid: Int32) -> Self? {
            guard pid > 0 else { return nil }
            // KERN_PROC_PID exposes the same basic metadata as ps, including
            // /usr/bin/login ancestors whose root UID blocks proc_pidinfo.
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.size
            var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&query, u_int(query.count), &info, &size, nil, 0) == 0,
                  size == MemoryLayout<kinfo_proc>.size, info.kp_proc.p_pid == pid,
                  info.kp_proc.p_stat != SZOMB else { return nil }
            var buffer = [CChar](repeating: 0, count: 128)
            let device = devname_r(info.kp_eproc.e_tdev, S_IFCHR, &buffer, Int32(buffer.count))
            let tty = device == nil ? nil : normalizeTTY(String(cString: buffer))
            let start = info.kp_proc.p_un.__p_starttime
            return Self(pid: pid, parentPID: info.kp_eproc.e_ppid,
                startedAt: Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000),
                tty: tty, userID: info.kp_eproc.e_ucred.cr_uid)
        }
    }

    enum Kind: String, Sendable {
        case ghostty = "com.mitchellh.ghostty"
        case iterm = "com.googlecode.iterm2"
        var name: String { self == .ghostty ? "Ghostty" : "iTerm2" }
    }

    struct Application: Sendable {
        let pid: Int32
        let kind: Kind
        let bundleURL: URL
    }

    struct Target: Sendable {
        let agent: ProcessIdentity
        let application: Application
        let terminalProcess: ProcessIdentity
        let tty: String
    }

    enum Failure: Error, Equatable, LocalizedError {
        case staleAgent, noTTY, unsupportedTerminal, unsupportedGhostty, ambiguous, missing, permission, timeout, automation, cancelled

        var errorDescription: String? {
            switch self {
            case .staleAgent: return "Процесс агента уже завершился или изменился"
            case .noTTY: return "У агента нет локального терминала"
            case .unsupportedTerminal: return "Точный переход доступен только в локальные вкладки Ghostty и iTerm2, без tmux/SSH"
            case .unsupportedGhostty: return "Эта версия Ghostty не предоставляет TTY вкладок. Точный переход недоступен"
            case .ambiguous: return "Найдено несколько панелей с одним TTY — выбери вкладку вручную"
            case .missing: return "Вкладка агента уже закрыта или недоступна"
            case .permission: return "Разреши drem управлять терминалом: Системные настройки → Конфиденциальность → Автоматизация"
            case .timeout: return "Терминал не ответил. Проверь запрос разрешения macOS и повтори"
            case .automation: return "Терминал не разрешил переход. В Ghostty нужна включённая настройка macos-applescript"
            case .cancelled: return "Переход отменён"
            }
        }
    }

    @MainActor
    static func runningApplications() -> [Application] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let id = app.bundleIdentifier, let kind = Kind(rawValue: id), let url = app.bundleURL else { return nil }
            return Application(pid: app.processIdentifier, kind: kind, bundleURL: url)
        }
    }

    static func normalizeTTY(_ value: String) -> String? {
        let name = value.hasPrefix("/dev/") ? String(value.dropFirst(5)) : value
        guard name.hasPrefix("tty"), name.count > 3, name.count < 80,
              name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { return nil }
        return "/dev/" + name
    }

    static func resolve(pid: Int32, startedAt: Date, applications: [Application],
                        read: (Int32) -> ProcessIdentity? = ProcessIdentity.read) throws -> Target {
        guard let agent = read(pid), agent.userID == getuid(), agent.startedAt == startedAt else { throw Failure.staleAgent }
        guard let tty = agent.tty, normalizeTTY(tty) == tty else { throw Failure.noTTY }
        var ancestor = agent
        var seen: Set<Int32> = [pid]
        for _ in 0..<32 {
            guard let parent = read(ancestor.parentPID), seen.insert(parent.pid).inserted else { break }
            if let app = applications.first(where: { $0.pid == parent.pid }) {
                return Target(agent: agent, application: app, terminalProcess: parent, tty: tty)
            }
            ancestor = parent
        }
        throw Failure.unsupportedTerminal
    }

    /// Inspect the installed dictionary before sending any Apple events. Old
    /// Ghostty has tab IDs but no PID/TTY mapping; titles/cwd are not identities.
    static func supportsExactNavigation(_ app: Application) -> Bool {
        guard app.kind == .ghostty else { return true }
        let url = app.bundleURL.appendingPathComponent("Contents/Resources/Ghostty.sdef")
        guard let data = try? Data(contentsOf: url), data.count < 512_000,
              let doc = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]),
              let nodes = try? doc.nodes(forXPath: "//class[@name='terminal']/property[@name='tty']") else { return false }
        return !nodes.isEmpty
    }

    static func open(pid: Int32, startedAt: Date, applications: [Application]) -> Result<Void, Failure> {
        do {
            let target = try resolve(pid: pid, startedAt: startedAt, applications: applications)
            guard supportsExactNavigation(target.application) else { throw Failure.unsupportedGhostty }
            try focus(target)
            return .success(())
        } catch let failure as Failure { return .failure(failure) }
        catch { return .failure(.automation) }
    }

    static func focus(_ target: Target, read: (Int32) -> ProcessIdentity? = ProcessIdentity.read,
                      execute: (String) throws -> String = run) throws {
        guard !Task.isCancelled else { throw Failure.cancelled }
        // First call may wait for a system Automation permission prompt.
        // Resolve read-only, then revalidate the kernel identity before focus.
        let terminalID = try execute(script(for: target, terminalID: nil))
        guard validTerminalID(terminalID) else { throw Failure.missing }
        guard !Task.isCancelled else { throw Failure.cancelled }
        guard read(target.agent.pid) == target.agent,
              read(target.application.pid) == target.terminalProcess else { throw Failure.staleAgent }
        let focused = try execute(script(for: target, terminalID: terminalID))
        guard focused == "focused" else { throw Failure.missing }
    }

    static func validTerminalID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
        }
    }

    static func script(for target: Target, terminalID: String?) -> String {
        // Inputs originate in kernel/Apple-event metadata, but still whitelist
        // every interpolated field. No shell interpolation or terminal input.
        guard normalizeTTY(target.tty) == target.tty,
              terminalID.map(validTerminalID) ?? true else { return "return \"missing\"" }
        let idCheck = terminalID.map { " and candidateID is \"\($0)\"" } ?? ""
        let collect: String
        let focus: String
        switch target.application.kind {
        case .ghostty:
            collect = """
            repeat with pane in terminals
                if tty of pane is "\(target.tty)" then
                    set candidateID to id of pane
                    if candidateID is not ""\(idCheck) then set end of matches to pane
                end if
            end repeat
            """
            focus = "focus chosen"
        case .iterm:
            collect = """
            repeat with win in windows
                repeat with tabItem in tabs of win
                    repeat with pane in sessions of tabItem
                        if tty of pane is "\(target.tty)" then
                            set candidateID to unique ID of pane
                            if candidateID is not ""\(idCheck) then set end of matches to {pane, tabItem, win}
                        end if
                    end repeat
                end repeat
            end repeat
            """
            focus = """
            select (item 1 of chosen)
            select (item 2 of chosen)
            select (item 3 of chosen)
            """
        }
        let resultID = target.application.kind == .ghostty ? "id of chosen" : "unique ID of (item 1 of chosen)"
        let action = terminalID == nil ? "return \(resultID)" : "\(focus)\nactivate\nreturn \"focused\""
        return """
        if application id "\(target.application.kind.rawValue)" is not running then return "missing"
        try
            with timeout of 25 seconds
                tell application id "\(target.application.kind.rawValue)"
                    set matches to {}
                    \(collect)
                    if (count of matches) is 0 then return "missing"
                    if (count of matches) is not 1 then return "ambiguous"
                    set chosen to item 1 of matches
                    \(action)
                end tell
            end timeout
        on error number errorNumber
            return "error:" & errorNumber
        end try
        """
    }

    private static func run(_ script: String) throws -> String {
        let result = BoundedProcessRunner.run("/usr/bin/osascript", ["-e", script], timeout: 30, maxOutputBytes: 1024)
        if result.timedOut { throw Failure.timeout }
        guard result.status == 0 else { throw Failure.automation }
        let text = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        switch text {
        case "error:-1743", "error:-1744": throw Failure.permission
        case "error:-1712": throw Failure.timeout
        case "missing": throw Failure.missing
        case "ambiguous": throw Failure.ambiguous
        default:
            guard !text.hasPrefix("error:") else { throw Failure.automation }
            return text
        }
    }
}
