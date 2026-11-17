// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 drem contributors

import DremCore
import Foundation

enum KeepAwakeDefaultsKey {
    static let defaultDuration = "defaultDurationMinutes"
    static let batteryLimit = "batteryLimitPercent"
    static let autoStart = "keepAwakeAutoStart"
    static let rightClickToggle = "keepAwakeRightClickToggle"
    static let allowDisplaySleep = "keepAwakeAllowDisplaySleep"
    static let externalDisplay = "keepAwakeExternalDisplay"
    static let connectedToPower = "keepAwakeConnectedToPower"
    static let whileAgentsWork = "keepAwakeWhileAgentsWork"
    static let awayMode = "keepAwakeAwayMode"
    static let pauseWhenLocked = "keepAwakePauseWhenLocked"
    static let hotkeyEnabled = "keepAwakeHotkeyEnabled"
    static let shortcut = "keepAwakeShortcut"
    static let clamshellPreferred = "keepAwakeClamshellPreferred"
    static let sleepDisabledFlag = "dremDisabledSleep"
}

enum KeepAwakePreferences {
    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            KeepAwakeDefaultsKey.defaultDuration: 0,
            KeepAwakeDefaultsKey.batteryLimit: 10,
            KeepAwakeDefaultsKey.autoStart: false,
            KeepAwakeDefaultsKey.rightClickToggle: false,
            KeepAwakeDefaultsKey.allowDisplaySleep: false,
            KeepAwakeDefaultsKey.externalDisplay: false,
            KeepAwakeDefaultsKey.connectedToPower: false,
            KeepAwakeDefaultsKey.whileAgentsWork: false,
            KeepAwakeDefaultsKey.awayMode: false,
            KeepAwakeDefaultsKey.pauseWhenLocked: false,
            KeepAwakeDefaultsKey.hotkeyEnabled: true,
            KeepAwakeDefaultsKey.shortcut: "control+option+command:40",
            KeepAwakeDefaultsKey.clamshellPreferred: false,
            KeepAwakeDefaultsKey.sleepDisabledFlag: false,
        ])

        sanitizeStoredValues(in: defaults)
    }

    private static func sanitizeStoredValues(in defaults: UserDefaults) {

        let duration = defaults.integer(forKey: KeepAwakeDefaultsKey.defaultDuration)
        if KeepAwakePolicy.sanitizedDuration(duration) != duration {
            defaults.set(0, forKey: KeepAwakeDefaultsKey.defaultDuration)
        }

        let battery = defaults.integer(forKey: KeepAwakeDefaultsKey.batteryLimit)
        if !KeepAwakePolicy.allowedBatteryLimits.contains(battery) {
            defaults.set(10, forKey: KeepAwakeDefaultsKey.batteryLimit)
        }

        if GlobalShortcut(storageValue: defaults.string(forKey: KeepAwakeDefaultsKey.shortcut) ?? "") == nil {
            defaults.set(GlobalShortcut.defaultKeepAwake.storageValue, forKey: KeepAwakeDefaultsKey.shortcut)
        }
    }
}
