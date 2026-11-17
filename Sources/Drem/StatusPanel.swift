import DremCore
import SwiftUI

// Deduplicate visible values, not engine events. Token timestamps must not
// invalidate the menu or reorder its rows while a task is running.
struct AgentMenuState: Equatable {
    struct Row: Equatable, Identifiable {
        struct Session: Equatable, Identifiable {
            let id: String
            let project: String
        }
        let kind: AgentKind
        let state: AgentActivity
        let sessions: [Session]
        var id: AgentKind { kind }
        var detail: String {
            switch state {
            case .working: return sessions.map(\.project).joined(separator: ", ")
            case .idle: return "Ожидает задачу"
            case .offline: return "Не запущен"
            }
        }
    }
    let isLoading: Bool
    let rows: [Row]
    var workingCount: Int { rows.reduce(0) { $0 + $1.sessions.count } }

    init(snapshot: AgentSnapshot) {
        isLoading = snapshot.capturedAt == .distantPast
        rows = AgentKind.allCases.map { kind in
            let status = snapshot.status(for: kind)
            return Row(kind: kind, state: status.state, sessions: status.workingSessions
                .map { Row.Session(id: $0.id, project: $0.projectName ?? "Сессия") }
                .sorted { $0.id < $1.id })
        }
    }
}

struct StatusPanel: View {
    @ObservedObject var presentation: AgentMenuPresentation
    let keepAwake: KeepAwakeManager
    @ObservedObject var awayMode: AwayModeController
    let openSettings: () -> Void
    let refresh: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("drem").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.bottom, 10)
            ForEach(presentation.state.rows) { row in
                AgentMenuRow(row: row, isLoading: presentation.state.isLoading)
            }
            Divider().padding(.vertical, 10)
            KeepAwakeControls(awake: keepAwake, awayMode: awayMode)
            if let error = presentation.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            Divider().padding(.top, 10).padding(.bottom, 6)
            HStack(spacing: 4) {
                Button("Настройки…", action: openSettings)
                    .keyboardShortcut(",", modifiers: .command)
                Spacer()
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise").frame(width: 24, height: 24)
                }
                .disabled(presentation.isRefreshing)
                .help("Обновить агентов")
                .accessibilityLabel("Обновить агентов")
                Button { NSApp.terminate(nil) } label: {
                    Image(systemName: "power").frame(width: 24, height: 24)
                }
                .help("Завершить drem")
                .accessibilityLabel("Завершить drem")
                .keyboardShortcut("q", modifiers: .command)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        // The native NSPopover supplies material, corners and shadow.
    }
    private var summary: String {
        if presentation.state.isLoading { return "Проверка…" }
        let count = presentation.state.workingCount
        return count == 0 ? "Нет активных задач" : "В работе: \(count)"
    }
}

private struct AgentMenuRow: View {
    let row: AgentMenuState.Row
    let isLoading: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.kind == .codex ? "terminal" : "sparkle")
                .font(.system(size: 16)).foregroundStyle(.secondary)
                .frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.kind.displayName).font(.system(size: 13, weight: .medium))
                Text(isLoading ? "Проверка…" : row.detail)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(row.detail)
            }
            Spacer(minLength: 8)
            if row.state == .working, !isLoading {
                HStack(spacing: 5) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text("Работает").font(.system(size: 11))
                }.foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 46)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.kind.displayName): \(isLoading ? "Проверка" : row.state == .working ? "Работает, \(row.detail)" : row.detail)")
    }
}
