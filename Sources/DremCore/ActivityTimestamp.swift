import Foundation

/// ISO formatters are expensive to construct and must not be mutated concurrently.
/// One synchronized pair covers legacy seconds and current fractional timestamps.
enum ActivityTimestamp {
    private static let lock = NSLock()
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let seconds = ISO8601DateFormatter()

    static func parse(_ string: String?) -> Date? {
        guard let string else { return nil }
        lock.lock(); defer { lock.unlock() }
        return fractional.date(from: string) ?? seconds.date(from: string)
    }

    static func string(_ date: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        return fractional.string(from: date)
    }
}
