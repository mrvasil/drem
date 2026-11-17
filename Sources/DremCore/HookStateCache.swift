import Foundation

/// Actor-owned cache. Reconciliation stats every file but decodes only changed
/// records, including same-size rewrites and atomic replacements. Deletions and
/// corrupt replacements remove evidence instead of retaining stale work.
final class HookStateCache {
    private struct Entry {
        let fingerprint: FileFingerprint
        let record: HookStateRecord?
        let priority: Int
    }
    private let store: HookStateStore
    private var entries: [String: Entry] = [:]
    private(set) var records: [HookStateRecord] = []
    private(set) var decodedFileCount = 0

    init(store: HookStateStore) { self.store = store }

    func containsEventPath(_ path: String) -> Bool {
        store.observedDirectoryURLs.contains { path == $0.path || path.hasPrefix($0.path + "/") }
    }

    func refresh() {
        var current: [String: Entry] = [:]
        for (priority, directory) in store.observedDirectoryURLs.enumerated() {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for file in files where file.pathExtension == "json" {
                guard let fingerprint = FileFingerprint(path: file.path) else { continue }
                if let cached = entries[file.path], cached.fingerprint == fingerprint {
                    current[file.path] = cached
                } else {
                    decodedFileCount += 1
                    current[file.path] = Entry(fingerprint: fingerprint, record: store.readRecord(at: file), priority: priority)
                }
            }
        }
        entries = current
        var latest: [String: HookStateRecord] = [:]
        // Prefer the current directory when legacy and current records tie.
        for entry in entries.values.sorted(by: { $0.priority < $1.priority }) {
            guard let record = entry.record else { continue }
            let key = record.kind.rawValue + ":" + record.sessionID
            if let previous = latest[key], previous.updatedAt >= record.updatedAt { continue }
            latest[key] = record
        }
        records = latest.values.sorted { $0.updatedAt > $1.updatedAt }
    }
}

struct FileFingerprint: Equatable {
    let identity: UInt64
    let size: UInt64
    let modified: Date
    let created: Date

    init?(path: String) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let identity = attributes[.systemFileNumber] as? NSNumber,
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        self.identity = identity.uint64Value
        self.size = size.uint64Value
        self.modified = modified
        created = attributes[.creationDate] as? Date ?? .distantPast
    }
}
