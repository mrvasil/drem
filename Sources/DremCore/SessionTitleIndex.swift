import Foundation

/// Saved, user-visible names only: no prompt excerpts, summaries or model calls.
public enum SessionTitle {
    public static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let controls = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}"))
        let safe = value.unicodeScalars.filter { !controls.contains($0) }
        let text = String(String.UnicodeScalarView(safe)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return text.isEmpty ? nil : String(text.prefix(96))
    }

    static func consume(_ objects: [[String: Any]], kind: AgentKind, previous: String? = nil) -> String? {
        guard kind == .claude else { return previous }
        var title = previous
        for object in objects where object["type"] as? String == "custom-title" {
            if let name = clean(object["customTitle"] as? String) { title = name }
        }
        return title
    }
}

struct SessionTitleIndex {
    let url: URL
    init(homeDirectory: URL) { url = homeDirectory.appendingPathComponent(".codex/session_index.jsonl") }
    func contains(_ path: String) -> Bool { URL(fileURLWithPath: path).standardizedFileURL == url.standardizedFileURL }
    func read() -> [String: String] {
        guard let file = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? file.close() }
        guard let size = try? file.seekToEnd() else { return [:] }
        let offset = size > 1_048_576 ? size - 1_048_576 : 0
        try? file.seek(toOffset: offset)
        guard var data = try? file.read(upToCount: 1_048_576) else { return [:] }
        if offset > 0, let newline = data.firstIndex(of: 10) { data = Data(data[data.index(after: newline)...]) }
        var result: [String: String] = [:]
        for object in JSONObjects.lines(in: String(decoding: data, as: UTF8.self)) {
            guard let id = object["id"] as? String, let title = SessionTitle.clean(object["thread_name"] as? String) else { continue }
            result[id] = title
        }
        return result
    }
}
