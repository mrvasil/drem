import Foundation

/// Cheap event routing before actor work or disk reads. Root events represent
/// coalesced/dropped FSEvents and deliberately request recovery discovery.
public struct ActivityEventPaths: Sendable {
    private let roots: [String]
    private let hooks: [String]
    private let codex: String
    private let claude: String

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        codex = homeDirectory.appendingPathComponent(".codex").path
        claude = homeDirectory.appendingPathComponent(".claude").path
        hooks = HookStateStore(homeDirectory: homeDirectory).observedDirectoryURLs.map(\.path)
        roots = [homeDirectory.path, codex, claude, codex + "/sessions", claude + "/projects", claude + "/sessions"] + hooks
    }

    public func requiresDiscovery(_ path: String) -> Bool { roots.contains(path) }

    public func contains(_ path: String) -> Bool {
        if requiresDiscovery(path) { return true }
        if path.hasPrefix(codex + "/sessions/") || path.hasPrefix(claude + "/projects/") {
            return path.hasSuffix(".jsonl")
        }
        if path.hasPrefix(claude + "/sessions/") { return path.hasSuffix(".json") }
        if hooks.contains(where: { path.hasPrefix($0 + "/") }) { return path.hasSuffix(".json") }
        return path == codex + "/goals_1.sqlite" || path == codex + "/goals_1.sqlite-wal"
    }
}
