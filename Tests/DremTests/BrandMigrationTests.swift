import Foundation
import Testing
@testable import Drem

struct BrandMigrationTests {
    @Test func migrationPreservesSettingsAndRecoveryWithoutChangingLegacy() throws {
        let brightness = Data([1, 2, 3])
        let legacy: [String: Any] = [
            "keepAwakeWhileAgentsWork": true,
            "keepAwakeClamshellPreferred": true,
            "agentWatchDisabledSleep": true,
            "closedLidBrightnessRestore": brightness,
            "keepAwakeShortcut": "control+option+command:40",
            "batteryLimitPercent": 15,
        ]
        let result = DremMigration.mergedPreferences(legacy: legacy, current: [:])
        #expect(result["keepAwakeWhileAgentsWork"] as? Bool == true)
        #expect(result["keepAwakeClamshellPreferred"] as? Bool == true)
        #expect(result["dremDisabledSleep"] as? Bool == true)
        #expect(result["agentWatchDisabledSleep"] == nil)
        #expect(result["closedLidBrightnessRestore"] as? Data == brightness)
        #expect(result["batteryLimitPercent"] as? Int == 15)
        #expect(result["keepAwakeShortcut"] as? String == "control+option+command:40")
        #expect(legacy["agentWatchDisabledSleep"] as? Bool == true)
    }

    @Test func currentChoicesWinAndCompletedMigrationDoesNotResurrectRecovery() throws {
        let legacy: [String: Any] = [
            "agentWatchDisabledSleep": true,
            "closedLidBrightnessRestore": Data([1]),
            "batteryLimitPercent": 10,
        ]
        var migrated = DremMigration.mergedPreferences(
            legacy: legacy,
            current: ["batteryLimitPercent": 20, "dremDisabledSleep": false]
        )
        #expect(migrated["batteryLimitPercent"] as? Int == 20)
        #expect(migrated["dremDisabledSleep"] as? Bool == false)
        migrated.removeValue(forKey: "closedLidBrightnessRestore")
        let again = DremMigration.mergedPreferences(legacy: legacy, current: migrated)
        #expect(again["closedLidBrightnessRestore"] == nil)
        #expect(again["dremDisabledSleep"] as? Bool == false)
    }

    @Test func migrationWritesOnlyTheTargetDomain() throws {
        let prefix = "drem-migration-test." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: prefix))
        let old = prefix + ".legacy", new = prefix + ".current"
        defer {
            defaults.removePersistentDomain(forName: old)
            defaults.removePersistentDomain(forName: new)
            defaults.removePersistentDomain(forName: prefix)
        }
        defaults.setPersistentDomain(["agentWatchDisabledSleep": true], forName: old)
        DremMigration.migratePreferences(defaults: defaults, from: old, to: new)
        #expect(defaults.persistentDomain(forName: old)?["agentWatchDisabledSleep"] as? Bool == true)
        #expect(defaults.persistentDomain(forName: new)?["dremDisabledSleep"] as? Bool == true)
    }
}
