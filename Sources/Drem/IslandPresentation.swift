import Combine
import CoreGraphics
import DremCore
import Foundation

enum IslandPreferences {
    static let enabled = "dremIslandEnabled"
    static let publicStatus = "dremIslandPublicStatus"
    static let showNotification = Notification.Name("drem.showIsland")
}

/// Local drawing coordinates have y increasing down; AppKit screen coordinates
/// have y increasing up. One path definition keeps paint and hit testing equal.
enum IslandOutline {
    static func path(in rect: CGRect, radius: CGFloat, flipped: Bool) -> CGPath {
        let r = min(max(0, radius), rect.width / 2, rect.height)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height - r))
        path.addArc(tangent1End: CGPoint(x: rect.width, y: rect.height),
                    tangent2End: CGPoint(x: rect.width - r, y: rect.height), radius: r)
        path.addLine(to: CGPoint(x: r, y: rect.height))
        path.addArc(tangent1End: CGPoint(x: 0, y: rect.height),
                    tangent2End: CGPoint(x: 0, y: rect.height - r), radius: r)
        path.closeSubpath()
        var transform = CGAffineTransform(a: 1, b: 0, c: 0, d: flipped ? 1 : -1,
                                         tx: rect.minX, ty: flipped ? rect.minY : rect.maxY)
        return path.copy(using: &transform) ?? path
    }
}

enum IslandHitRegion {
    static func contains(_ point: CGPoint, rect: CGRect, expanded: Bool) -> Bool {
        let radius: CGFloat = expanded ? 26 : 18
        return IslandOutline.path(in: rect, radius: radius, flipped: false).contains(point)
    }

    static func notchTarget(centerX: CGFloat, screenTop: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
        // Clicks just below the camera are intentional, without painting there.
        CGRect(x: centerX - width / 2 - 6, y: screenTop - height - 12, width: width + 12, height: height + 12)
    }
}

struct IslandSleepState: Equatable {
    var active = false
    var clamshell = false
    var paused = false
    var agentMode = false
    var preventsSleep: Bool { (active && !paused) || clamshell }
    var symbol: String { preventsSleep ? "sun.max.fill" : "moon.zzz" }
    var title: String {
        if clamshell { return "Mac не уснёт · даже с закрытой крышкой" }
        if active && !paused { return "Mac не уснёт · крышку оставь открытой" }
        if paused { return "Удержание сна на паузе" }
        return "drem не мешает Mac уснуть"
    }
    var detail: String {
        agentMode ? "После последнего агента drem снимет блокировки сна" : "По текущим настройкам drem"
    }
}

struct IslandCompletion: Equatable, Identifiable {
    let row: IslandRow
    let closed: Bool
    var id: String { row.id }
    var label: String { closed ? "Сессия закрыта" : "Завершил работу" }
}

/// Pure lifecycle reducer. The hidden latch belongs to a whole work cycle,
/// not a session ID; adding another agent cannot undo the user's dismissal.
struct IslandLifecycle: Equatable {
    enum Mode: Equatable { case absent, compact, preview, expanded, completed }
    private(set) var mode: Mode = .absent
    private(set) var workingCount = 0
    private(set) var dismissed = false
    private(set) var enabled = false
    private(set) var available = false
    private(set) var keepsAwake = false

    mutating func configure(enabled: Bool, available: Bool) {
        self.enabled = enabled
        self.available = available
        if !enabled || !available { mode = .absent }
        else if mode == .absent, workingCount > 0 || keepsAwake, !dismissed { mode = .compact }
    }

    mutating func wakeChanged(_ active: Bool) {
        keepsAwake = active
        if !active, workingCount == 0 { dismissed = false }
        if active, mode == .absent, enabled, available, !dismissed { mode = .compact }
        if !active, workingCount == 0, mode == .compact || mode == .preview { mode = .absent }
    }

    mutating func activityChanged(count: Int) {
        let previous = workingCount
        workingCount = max(0, count)
        if workingCount == 0 {
            let wasVisible = mode != .absent && !dismissed
            dismissed = false
            if previous > 0 { mode = enabled && available && wasVisible ? .completed : .absent }
        } else if previous == 0 {
            mode = enabled && available && !dismissed ? .compact : .absent
        }
    }

    mutating func hover(_ inside: Bool) {
        if inside, mode == .compact { mode = .preview }
        if !inside, mode == .preview { mode = .compact }
    }
    mutating func toggle() {
        guard mode != .absent else { return }
        mode = mode == .expanded ? .compact : .expanded
    }
    mutating func collapse() { if mode == .expanded { mode = .compact } }
    mutating func dismiss() {
        dismissed = workingCount > 0 || keepsAwake
        mode = .absent
    }
    mutating func restore(expanded: Bool = true) {
        dismissed = false
        if enabled, available { mode = expanded ? .expanded : .compact }
    }
    mutating func finishCompletion() { if mode == .completed { mode = keepsAwake ? .compact : .absent } }
}

struct IslandRow: Equatable, Identifiable {
    let id: String
    let kind: AgentKind
    let project: String
    let action: String
    let status: String?
    var headline: String? = nil
    var directory: String? = nil
    var processID: Int32? = nil
    var processStartedAt: Date? = nil
    var source: ActivitySource = .transcript
    var activity: AgentActivityDetail.Action = .working
    var sessionTitle: String? = nil
    var attention: AgentAttention? = nil

    private var avatarKey: String {
        if let directory {
            return "folder:\(URL(fileURLWithPath: directory).standardizedFileURL.path)"
        }
        // A bound working directory is the canonical identity. The visible
        // project name is only a stable fallback while that path is unavailable.
        return "project:\(project.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping)"
    }
    var avatarSeed: UInt64 {
        // Swift Hasher is randomized each launch. FNV keeps each session's
        // folder avatar stable between launches without reading prompt text.
        avatarKey.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }
    var colorIndex: Int { IslandBlobIdentity(seed: avatarSeed).colorIndex }
    func sessionName(showStatus: Bool) -> String? {
        guard showStatus, let title = sessionTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty, title.localizedCaseInsensitiveCompare(project) != .orderedSame else { return nil }
        return title
    }
    func name(showStatus: Bool) -> String {
        sessionName(showStatus: showStatus).map { project + " · " + $0 } ?? project
    }

    var shortID: String { String(id.split(separator: ":").last.map(String.init)?.suffix(6) ?? "") }
    var sourceTitle: String {
        switch source {
        case .goal: return "Цель /goal"
        case .hook: return "Событие агента"
        case .transcript: return "Локальная сессия"
        case .process: return "Процесс"
        }
    }
    func title(showStatus: Bool) -> String { attention?.title ?? (showStatus ? headline ?? action : action) }
    func copyText(showStatus: Bool) -> String {
        ([kind.displayName + " · " + project, attention?.title ?? action] + (showStatus ? [sessionTitle, headline, status].compactMap { $0 } : []))
            .joined(separator: "\n")
    }
    var projectURL: URL? {
        guard let directory, directory.hasPrefix("/"), !directory.contains("\0") else { return nil }
        return URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
    }

    static func rows(_ snapshot: AgentSnapshot) -> [IslandRow] {
        snapshot.statuses.flatMap(\.workingSessions).map { session in
            let detail = session.detail
            let action = detail?.action.title ?? "Работает"
            return IslandRow(id: session.kind.rawValue + ":" + session.id, kind: session.kind,
                project: session.projectName ?? "Сессия",
                action: detail?.fileName.map { action + " · " + $0 } ?? action,
                status: detail?.publicStatus, headline: detail?.headline,
                directory: session.workingDirectory, processID: session.processID,
                source: session.source, activity: detail?.action ?? .working, sessionTitle: session.sessionTitle,
                attention: detail?.attention)
        }.sorted { $0.id < $1.id }
    }
}

@MainActor
final class IslandPresentation: ObservableObject {
    @Published var lifecycle = IslandLifecycle()
    @Published var rows: [IslandRow] = []
    @Published private(set) var selectedID: String?
    private var lastFeaturedID: String?
    @Published var hoveredID: String?
    @Published var notchWidth: CGFloat = 180
    @Published var notchHeight: CGFloat = 32
    @Published var pointer: CGFloat = 0
    @Published var showPublicStatus = true
    @Published var reduceMotion = false
    @Published var reduceTransparency = false
    @Published var increaseContrast = false
    @Published var isPresented = false
    @Published var sleep = IslandSleepState()
    @Published private(set) var completions: [IslandCompletion] = []
    @Published private(set) var reaction = 0
    @Published var pointerY: CGFloat = 0
    @Published var gesture: IslandSwipe.Feedback?
    var screenTop: CGFloat = 0

    var selectedRow: IslandRow? { rows.first { $0.id == selectedID } }
    var attentionRows: [IslandRow] { rows.filter { $0.attention != nil } }
    var attentionCount: Int { attentionRows.count }
    var featuredRow: IslandRow? {
        selectedRow ?? rows.first { $0.id == hoveredID }
            ?? attentionRows.first ?? rows.first { $0.id == lastFeaturedID } ?? rows.first ?? completions.first?.row
    }
    func react() { reaction += 1 }
    func receive(_ snapshot: AgentSnapshot) {
        let next = IslandRow.rows(snapshot).map { row in
            var bound = row
            // Capture once for a new binding, not on every transcript write.
            // Keeping the old timestamp also rejects a recycled PID on click.
            if let old = rows.first(where: { $0.id == row.id && $0.processID == row.processID }) {
                bound.processStartedAt = old.processStartedAt
            } else if let pid = row.processID {
                bound.processStartedAt = ProcessLiveness.startTime(pid)
            }
            return bound
        }
        let sessions = snapshot.statuses.flatMap(\.sessions)
        let ended = rows.filter { old in !next.contains { $0.id == old.id } }.map { old in
            // Completion is historical identity, not a live pending request.
            // It can remain featured after the last working row disappears.
            var completed = old
            completed.attention = nil
            return IslandCompletion(row: completed, closed: !sessions.contains { $0.kind.rawValue + ":" + $0.id == old.id })
        }
        if !ended.isEmpty {
            completions = Array((ended + completions.filter { old in !ended.contains { $0.id == old.id } }).prefix(4))
            react()
        }
        let remaining = completions.filter { done in !next.contains { $0.id == done.id } }
        if completions != remaining { completions = remaining }
        replaceRows(next)
        if lifecycle.workingCount != next.count { lifecycle.activityChanged(count: next.count) }
    }
    func clearCompletions() { completions = [] }
    func select(_ id: String) {
        guard rows.contains(where: { $0.id == id }) else { return }
        lastFeaturedID = id
        selectedID = id
    }
    func showOverview() { selectedID = nil }
    func replaceRows(_ value: [IslandRow]) {
        if rows != value { rows = value }
        if !value.contains(where: { $0.id == selectedID }) { selectedID = nil }
        if !value.contains(where: { $0.id == lastFeaturedID }) { lastFeaturedID = nil }
        if !value.contains(where: { $0.id == hoveredID }) { hoveredID = nil }
    }

    var expandedWidth: CGFloat { max(600, notchWidth + 260) }
    var width: CGFloat {
        switch lifecycle.mode {
        case .expanded: return expandedWidth
        default: return notchWidth + 132
        }
    }
    var height: CGFloat {
        switch lifecycle.mode {
        case .expanded: return notchHeight + 216
        default: return notchHeight
        }
    }
    var canvasHeight: CGFloat { notchHeight + 216 }
}
