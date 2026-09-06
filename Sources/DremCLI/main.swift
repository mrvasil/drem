import DremCore
import Foundation

do {
    // Use the same hook/transcript reconciliation as the menu-bar app.
    let snapshot = try await LiveActivityEngine().bootstrap().snapshot
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(snapshot)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("dremctl: \(error.localizedDescription)\n".utf8))
    exit(1)
}
