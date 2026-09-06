import Foundation
import Testing
@testable import Drem

struct BrandMigrationTests {
    @Test func migrationPreservesSettingsAndRecoveryWithoutChangingLegacy() throws {
        let brightness = Data([1, 2, 3])
        let legacy: [String: Any] = [
            "keepAwakeWhileAgentsWork": true,
            "keepAwakeClamshellPreferred": true,
            "keepAwakeActiveIcon": "agentWatch",
            "keepAwakeIconTint": "orange",
            "agentWatchDisabledSleep": true,
            "closedLidBrightnessRestore": brightness,
            "keepAwakeShortcut": "control+option+command:40",
            "batteryLimitPercent": 15,
        ]
        let result = DremMigration.mergedPreferences(legacy: legacy, current: [:])
        #expect(result["keepAwakeWhileAgentsWork"] as? Bool == true)
        #expect(result["keepAwakeClamshellPreferred"] as? Bool == true)
        #expect(result["keepAwakeActiveIcon"] as? String == "drem")
        #expect(result["keepAwakeIconTint"] as? String == "orange")
        #expect(result["dremDisabledSleep"] as? Bool == true)
        #expect(result["agentWatchDisabledSleep"] == nil)
        #expect(result["closedLidBrightnessRestore"] as? Data == brightness)
        #expect(result["batteryLimitPercent"] as? Int == 15)
        #expect(result["keepAwakeShortcut"] as? String == "control+option+command:40")
        #expect(legacy["keepAwakeActiveIcon"] as? String == "agentWatch")
    }

    @Test func currentChoicesWinAndCompletedMigrationDoesNotResurrectRecovery() throws {
        let legacy: [String: Any] = [
            "keepAwakeActiveIcon": "agentWatch",
            "keepAwakeIconTint": "orange",
            "agentWatchDisabledSleep": true,
            "closedLidBrightnessRestore": Data([1]),
        ]
        var migrated = DremMigration.mergedPreferences(
            legacy: legacy,
            current: ["keepAwakeActiveIcon": "moon", "keepAwakeIconTint": "blue", "dremDisabledSleep": false]
        )
        #expect(migrated["keepAwakeActiveIcon"] as? String == "moon")
        #expect(migrated["keepAwakeIconTint"] as? String == "blue")
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
        defaults.setPersistentDomain(["keepAwakeActiveIcon": "agentWatch"], forName: old)
        DremMigration.migratePreferences(defaults: defaults, from: old, to: new)
        #expect(defaults.persistentDomain(forName: old)?["keepAwakeActiveIcon"] as? String == "agentWatch")
        #expect(defaults.persistentDomain(forName: new)?["keepAwakeActiveIcon"] as? String == "drem")
    }
}
