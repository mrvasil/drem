import DremCore
import Foundation
import Testing

struct LegacyHookTests {
    @Test func legacyHookUpdatesRemainReadableAndSessionEndClearsBothGenerations() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = HookStateStore(homeDirectory: home)
        func input(_ event: String) throws -> HookInput {
            let value = ["session_id": "demo-session", "cwd": "/tmp/demo", "hook_event_name": event]
            return try JSONDecoder().decode(HookInput.self, from: JSONSerialization.data(withJSONObject: value))
        }
        try store.record(input: input("UserPromptSubmit"), kind: .codex, processID: 123)
        let current = store.directoryURL.appendingPathComponent("codex-demo-session.json")
        let legacyDirectory = home.appendingPathComponent("Library/Application Support/AgentWatch/state", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let legacy = legacyDirectory.appendingPathComponent(current.lastPathComponent)
        try FileManager.default.moveItem(at: current, to: legacy)
        #expect(store.observedDirectoryURLs.contains(legacyDirectory))
        #expect(store.readAll().first?.state == .working)

        try store.record(input: input("Stop"), kind: .codex, processID: 123)
        #expect(store.readAll().count == 1)
        #expect(store.readAll().first?.state == .idle)
        try store.record(input: input("SessionEnd"), kind: .codex, processID: 123)
        #expect(store.readAll().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(!FileManager.default.fileExists(atPath: current.path))
    }
}
