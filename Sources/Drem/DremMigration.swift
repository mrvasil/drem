import Foundation

/// One-way, non-destructive migration from the pre-drem application.
/// Existing drem choices win. The legacy domain remains available for rollback.
enum DremMigration {
    static let legacyDomain = "local.mrvasil.AgentWatch"
    static let currentDomain = "local.mrvasil.drem"
    static let marker = "dremMigrationV1Completed"

    static func mergedPreferences(legacy: [String: Any], current: [String: Any]) -> [String: Any] {
        if current[marker] as? Bool == true { return current }
        var result = legacy.merging(current) { _, new in new }
        if result["dremDisabledSleep"] == nil, let saved = result["agentWatchDisabledSleep"] {
            result["dremDisabledSleep"] = saved
        }
        result.removeValue(forKey: "agentWatchDisabledSleep")
        if result["keepAwakeActiveIcon"] as? String == "agentWatch" {
            result["keepAwakeActiveIcon"] = "drem"
        }
        result[marker] = true
        return result
    }

    static func migratePreferences(
        defaults: UserDefaults = .standard,
        from legacy: String = legacyDomain,
        to current: String = currentDomain
    ) {
        let existing = defaults.persistentDomain(forName: current) ?? [:]
        guard existing[marker] as? Bool != true else { return }
        let previous = defaults.persistentDomain(forName: legacy) ?? [:]
        defaults.setPersistentDomain(mergedPreferences(legacy: previous, current: existing), forName: current)
        defaults.synchronize()
    }
}
