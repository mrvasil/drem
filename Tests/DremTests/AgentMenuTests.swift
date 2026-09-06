import DremCore
import Combine
import Foundation
import Testing
@testable import Drem

@MainActor
struct AgentMenuTests {
    private func snapshot(_ state: AgentActivity, timestamp: Date = Date(), ids: [String] = ["one"]) -> AgentSnapshot {
        AgentSnapshot(capturedAt: timestamp, statuses: [
            AgentStatus(kind: .codex, state: state, runningProcessCount: state == .offline ? 0 : ids.count,
                sessions: state == .offline ? [] : ids.map {
                    AgentSessionActivity(id: $0, kind: .codex, state: state, updatedAt: timestamp,
                                         projectName: "demo-project", processID: 100, source: .transcript)
                })
        ])
    }

    @Test func timestampOnlyWritesDoNotRedrawTheMenu() {
        let events = PassthroughSubject<AgentSnapshot, Never>()
        var updates: [AgentMenuState] = []
        let subscription = events.map(AgentMenuState.init).removeDuplicates().sink { updates.append($0) }
        for second in 0..<1_000 {
            events.send(snapshot(.working, timestamp: Date(timeIntervalSince1970: Double(second))))
        }
        #expect(updates.count == 1)
        events.send(snapshot(.idle))
        events.send(snapshot(.working))
        events.send(snapshot(.offline))
        #expect(updates.map { $0.rows[0].state } == [.working, .idle, .working, .offline])
        withExtendedLifetime(subscription) {}
    }

    @Test func reorderedActivityDoesNotMoveProjectsAndSameDirectorySessionsStayDistinct() {
        let first = AgentMenuState(snapshot: snapshot(.working, ids: ["one", "two"]))
        let second = AgentMenuState(snapshot: snapshot(.working, ids: ["two", "one"]))
        #expect(first == second)
        #expect(first.workingCount == 2)
        #expect(first.rows[0].sessions.map(\.id) == ["one", "two"])
        #expect(first != AgentMenuState(snapshot: snapshot(.working, ids: ["two"])))
    }

    @Test func idleIsNotOfflineAndInitialStateIsNotAFinalResult() {
        let idle = AgentMenuState(snapshot: snapshot(.idle))
        let offline = AgentMenuState(snapshot: snapshot(.offline))
        #expect(idle != offline)
        #expect(idle.workingCount == 0)
        #expect(idle.rows[0].detail == "Ожидает задачу")
        #expect(offline.rows[0].detail == "Не запущен")
        #expect(AgentMenuState(snapshot: .empty).isLoading)
        #expect(!offline.isLoading)
    }
}
