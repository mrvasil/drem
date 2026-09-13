import Foundation
import SQLite3

/// Reads only lifecycle metadata from Codex's goal registry. Goal objectives
/// are intentionally outside drem's monitoring boundary.
public struct CodexGoalRegistry: Sendable {
    public let databaseURL: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        databaseURL = homeDirectory.appendingPathComponent(".codex/goals_1.sqlite")
    }

    public var observedPaths: [String] {
        let path = databaseURL.standardizedFileURL.path
        return [path, path + "-wal", path + "-shm"]
    }

    public func containsEventPath(_ path: String) -> Bool {
        observedPaths.contains(URL(fileURLWithPath: path).standardizedFileURL.path)
    }

    public func readActiveGoals() throws -> [String: Date] {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return [:] }

        var connection: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &connection,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
            nil
        )
        guard result == SQLITE_OK, let connection else {
            defer { if let connection { sqlite3_close(connection) } }
            throw RegistryError.open(message: connection.flatMap(Self.errorMessage) ?? "SQLite error \(result)")
        }
        defer { sqlite3_close(connection) }

        // Keep an event callback bounded if Codex happens to hold a short lock.
        sqlite3_busy_timeout(connection, 100)

        var statement: OpaquePointer?
        let sql = "SELECT thread_id, updated_at_ms FROM thread_goals WHERE status = 'active'"
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw RegistryError.query(message: Self.errorMessage(connection))
        }
        defer { sqlite3_finalize(statement) }

        var goals: [String: Date] = [:]
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let rawThreadID = sqlite3_column_text(statement, 0) else { continue }
                let threadID = String(cString: rawThreadID)
                let updatedAtMilliseconds = sqlite3_column_int64(statement, 1)
                goals[threadID] = Date(
                    timeIntervalSince1970: Double(updatedAtMilliseconds) / 1_000
                )
            case SQLITE_DONE:
                return goals
            default:
                throw RegistryError.query(message: Self.errorMessage(connection))
            }
        }
    }

    private static func errorMessage(_ connection: OpaquePointer) -> String {
        sqlite3_errmsg(connection).map { String(cString: $0) } ?? "Unknown SQLite error"
    }

    private enum RegistryError: LocalizedError {
        case open(message: String)
        case query(message: String)

        var errorDescription: String? {
            switch self {
            case .open(let message): return "Не удалось открыть реестр целей Codex: \(message)"
            case .query(let message): return "Не удалось прочитать реестр целей Codex: \(message)"
            }
        }
    }
}
