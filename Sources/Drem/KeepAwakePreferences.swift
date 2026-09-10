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
    static let mouseJiggleEnabled = "keepAwakeMouseJiggleEnabled"
    static let mouseJiggleInterval = "keepAwakeMouseJiggleIntervalMinutes"
    static let hotkeyEnabled = "keepAwakeHotkeyEnabled"
    static let shortcut = "keepAwakeShortcut"
    static let iconTint = "keepAwakeIconTint"
    static let activeIcon = "keepAwakeActiveIcon"
    static let showCountdown = "showKeepAwakeCountdownInMenuBar"
    static let clamshellPreferred = "keepAwakeClamshellPreferred"
    static let sleepDisabledFlag = "dremDisabledSleep"
}

enum KeepAwakeIconTint: String, CaseIterable, Identifiable {
    case orange, green, blue, purple, pink, none

    var id: String { rawValue }

    static var current: KeepAwakeIconTint {
        let raw = UserDefaults.standard.string(forKey: KeepAwakeDefaultsKey.iconTint)
        return KeepAwakeIconTint(rawValue: raw ?? "") ?? .none
    }

    var title: String {
        switch self {
        case .orange: return "Оранжевый"
        case .green: return "Зелёный"
        case .blue: return "Синий"
        case .purple: return "Фиолетовый"
        case .pink: return "Розовый"
        case .none: return "Системный"
        }
    }
}

enum KeepAwakeActiveIcon: String, CaseIterable, Identifiable {
    case drem, coffee, eye, moon, light

    var id: String { rawValue }

    static var current: KeepAwakeActiveIcon {
        let raw = UserDefaults.standard.string(forKey: KeepAwakeDefaultsKey.activeIcon)
        return KeepAwakeActiveIcon(rawValue: raw ?? "") ?? .drem
    }

    var systemSymbolName: String {
        switch self {
        case .drem: return "sparkle"
        case .coffee: return "cup.and.saucer.fill"
        case .eye: return "eye.fill"
        case .moon: return "moon.fill"
        case .light: return "lightbulb.fill"
        }
    }

    var title: String {
        switch self {
        case .drem: return "drem"
        case .coffee: return "Кофе"
        case .eye: return "Глаз"
        case .moon: return "Луна"
        case .light: return "Лампочка"
        }
    }
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
            KeepAwakeDefaultsKey.mouseJiggleEnabled: false,
            KeepAwakeDefaultsKey.mouseJiggleInterval: 5,
            KeepAwakeDefaultsKey.hotkeyEnabled: true,
            KeepAwakeDefaultsKey.shortcut: "control+option+command:40",
            KeepAwakeDefaultsKey.iconTint: KeepAwakeIconTint.none.rawValue,
            KeepAwakeDefaultsKey.activeIcon: KeepAwakeActiveIcon.drem.rawValue,
            KeepAwakeDefaultsKey.showCountdown: false,
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

        let jiggle = defaults.integer(forKey: KeepAwakeDefaultsKey.mouseJiggleInterval)
        if !KeepAwakePolicy.allowedMouseJiggleIntervals.contains(jiggle) {
            defaults.set(5, forKey: KeepAwakeDefaultsKey.mouseJiggleInterval)
        }

        if KeepAwakeIconTint(rawValue: defaults.string(forKey: KeepAwakeDefaultsKey.iconTint) ?? "") == nil {
            defaults.set(KeepAwakeIconTint.none.rawValue, forKey: KeepAwakeDefaultsKey.iconTint)
        }
        if KeepAwakeActiveIcon(rawValue: defaults.string(forKey: KeepAwakeDefaultsKey.activeIcon) ?? "") == nil {
            defaults.set(KeepAwakeActiveIcon.drem.rawValue, forKey: KeepAwakeDefaultsKey.activeIcon)
        }
        if GlobalShortcut(storageValue: defaults.string(forKey: KeepAwakeDefaultsKey.shortcut) ?? "") == nil {
            defaults.set(GlobalShortcut.defaultKeepAwake.storageValue, forKey: KeepAwakeDefaultsKey.shortcut)
        }
    }
}
