// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 drem contributors

import AppKit
import Combine
import UserNotifications

@main
enum DremApplication {
    static func main() {
        let application = NSApplication.shared
        let delegate = DremAppDelegate()
        application.delegate = delegate
        application.run()
    }
}

@MainActor
final class DremAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var monitor: AgentMonitor?
    private var statusController: StatusItemController?
    private var agentActivitySubscription: AnyCancellable?
    private var closedLidBrightness: ClosedLidBrightnessController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        DremMigration.migratePreferences()
        KeepAwakePreferences.registerDefaults()

        let monitor = AgentMonitor()
        let keepAwake = KeepAwakeManager.shared
        self.monitor = monitor
        agentActivitySubscription = monitor.$snapshot
            .map(\.hasWorkingAgent)
            .removeDuplicates()
            .sink { [weak keepAwake] working in
                keepAwake?.agentActivityDidChange(hasWorkingAgent: working)
            }
        statusController = StatusItemController(monitor: monitor, keepAwake: keepAwake)
        let brightness = ClosedLidBrightnessController()
        closedLidBrightness = brightness
        brightness.bind(to: keepAwake)
        brightness.start()

        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }

        let hotkey = KeepAwakeHotkeyManager.shared
        hotkey.onActivate = { KeepAwakeManager.shared.toggle() }
        hotkey.syncWithPreferences()

        keepAwake.onSessionEnded = { reason in
            switch reason {
            case .timer:
                KeepAwakeNotifier.post(
                    title: "Сеанс завершён",
                    body: "Mac снова следует обычным правилам сна."
                )
            case .battery:
                KeepAwakeNotifier.post(
                    title: "Удержание сна отключено",
                    body: "Достигнут заданный порог заряда батареи."
                )
            case .manual, .quit:
                break
            }
        }

        keepAwake.recoverIfNeeded {
            keepAwake.activateOnLaunchIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        closedLidBrightness?.shutdown()
        KeepAwakeManager.shared.deactivate(reason: .quit)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        statusController?.showPopover()
        return true
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
