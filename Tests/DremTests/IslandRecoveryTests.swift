import AppKit
import Testing
@testable import Drem

@MainActor @Suite(.serialized)
struct IslandRecoveryTests {
    private final class Environment {
        var reads = 0
        var value = IslandEnvironmentSnapshot(
            placement: .init(frame: CGRect(x: -4000, y: -4000, width: 1512, height: 982),
                             centerX: -3244, notchWidth: 185, notchHeight: 32),
            displayAsleep: false, sessionActive: true, locked: false, lidClosed: false)
    }

    private final class Panel: NSPanel {
        var orderingCount = 0
        var orderOutCount = 0
        override func orderFrontRegardless() {
            orderingCount += 1
            super.orderFrontRegardless()
        }
        override func orderOut(_ sender: Any?) {
            orderOutCount += 1
            super.orderOut(sender)
        }
    }

    private func fixture(observeSystem: Bool = false,
                         panelIsOnscreen: @escaping @MainActor (NSPanel) -> Bool = { $0.isVisible },
                         _ body: (IslandController, Panel, Environment, UserDefaults) async throws -> Void) async rethrows {
        _ = NSApplication.shared
        let suite = "DremIslandRecovery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let environment = Environment()
        let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        let controller = IslandController(defaults: defaults, panel: panel,
            environmentReader: {
                environment.reads += 1
                return environment.value
            }, panelIsOnscreen: panelIsOnscreen, observeSystem: observeSystem)
        defer {
            controller.shutdown()
            defaults.removePersistentDomain(forName: suite)
        }
        try await body(controller, panel, environment, defaults)
    }

    @Test func systemNotificationsNeverReenterTheCurrentViewUpdate() async {
        await fixture(observeSystem: true) { controller, panel, environment, defaults in
            controller.restore()
            await drainMainQueue()
            let reads = environment.reads
            // AppKit/font initialization can post this while NSHostingView is
            // attaching. Rebuilding the host inside post() reenters SwiftUI.
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
            #expect(environment.reads == reads, "Notification delivery must leave the current view-update stack")
            await drainMainQueue()
            #expect(environment.reads > reads)
            #expect(controller.presentation.isPresented)
            #expect(panel.isVisible)
        }
    }

    @Test func queuedNotificationsKeepTransitionOrderAndRespectShutdown() async {
        await fixture(observeSystem: true) { controller, panel, _, defaults in
            controller.restore()
            controller.presentation.lifecycle.activityChanged(count: 1)
            await drainMainQueue()
            let center = NSWorkspace.shared.notificationCenter
            center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
            center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
            await drainMainQueue()
            await drainMainQueue()
            #expect(controller.presentation.lifecycle.available)
            #expect(controller.presentation.isPresented)
            center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
            center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
            await drainMainQueue()
            #expect(!controller.presentation.lifecycle.available)
            #expect(panel.contentView == nil)
            let unrelated = UserDefaults(suiteName: "DremIslandRecovery.unrelated.(UUID().uuidString)")!
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: unrelated)
            await drainMainQueue()
            #expect(!controller.presentation.lifecycle.available,
                "An unrelated defaults store cannot clear a display sleep block")
            #expect(panel.contentView == nil)
            NotificationCenter.default.post(name: IslandPreferences.showNotification, object: nil)
            controller.shutdown()
            await drainMainQueue()
            #expect(!controller.presentation.isPresented)
            #expect(panel.contentView == nil)
        }
    }

    @Test func explicitShowWorksWithoutAgentsAndReplacesAnInvisibleHost() async throws {
        try await fixture { controller, panel, _, defaults in
            #expect(!defaults.bool(forKey: IslandPreferences.enabled))
            controller.restore()
            #expect(defaults.bool(forKey: IslandPreferences.enabled))
            #expect(controller.presentation.lifecycle.workingCount == 0)
            #expect(controller.presentation.lifecycle.mode == .expanded)
            #expect(controller.presentation.isPresented)
            let oldHost = try #require(panel.contentView)
            controller.presentation.isPresented = false
            panel.orderOut(nil)
            controller.restore()
            #expect(panel.contentView !== oldHost)
            #expect(controller.presentation.isPresented)
            #expect(panel.isVisible)
        }
    }

    @Test func freshSystemStateRecoversEvenWhenTheOppositeNotificationWasMissed() async {
        await fixture { controller, panel, environment, _ in
            controller.restore()
            controller.presentation.lifecycle.activityChanged(count: 1)
            for hint in ["display-sleep-event", "session-inactive-event", "screen-lock-event"] {
                controller.environmentChanged(blockingHint: hint)
                #expect(!controller.presentation.lifecycle.available)
                #expect(panel.contentView == nil)
                // No matching wake/unlock event: the next refresh reads the OS.
                controller.environmentChanged()
                await drainMainQueue()
                #expect(environment.value.blockedReason == nil)
                #expect(controller.presentation.lifecycle.mode == .compact)
                #expect(controller.presentation.isPresented)
                #expect(panel.contentView != nil)
            }
        }
    }

    @Test func explicitRestoreNeverBypassesRealLockSleepClosedLidOrMissingScreen() async {
        await fixture { controller, panel, environment, _ in
            let available = environment.value
            for reason in ["locked", "inactive-session", "display-asleep", "closed-lid", "unknown-lid", "no-notched-display"] {
                environment.value = available
                switch reason {
                case "locked": environment.value.locked = true
                case "inactive-session": environment.value.sessionActive = false
                case "display-asleep": environment.value.displayAsleep = true
                case "closed-lid": environment.value.lidClosed = true
                case "unknown-lid": environment.value.lidClosed = nil
                default: environment.value.placement = nil
                }
                controller.restore()
                await drainMainQueue()
                #expect(environment.value.blockedReason == reason)
                #expect(controller.presentation.lifecycle.mode == .absent)
                #expect(!controller.presentation.isPresented)
                #expect(panel.contentView == nil)
                #expect(!panel.isVisible)
            }
        }
    }

    @Test func settledRepairReordersWithoutLosingUserDismissal() async {
        await fixture { controller, panel, _, _ in
            controller.restore()
            controller.presentation.lifecycle.activityChanged(count: 1)
            let orders = panel.orderingCount
            controller.environmentChanged(reattachPanel: true)
            #expect(panel.orderingCount > orders, "A settled repair still reasserts the panel level")
            controller.presentation.lifecycle.dismiss()
            controller.environmentChanged()
            #expect(controller.presentation.lifecycle.dismissed)
            #expect(controller.presentation.lifecycle.mode == .absent)
            #expect(!controller.presentation.isPresented)
            controller.restore(expanded: false)
            #expect(controller.presentation.lifecycle.mode == .compact)
            #expect(controller.presentation.isPresented)
        }
    }

    @Test func activationAndSpaceChangesDoNotDetachAnOnscreenPanel() async throws {
        try await fixture(observeSystem: true, panelIsOnscreen: { _ in true }) { controller, panel, _, _ in
            controller.restore()
            controller.presentation.lifecycle.activityChanged(count: 1)
            await drainMainQueue()
            let orders = panel.orderingCount
            let removals = panel.orderOutCount
            let center = NSWorkspace.shared.notificationCenter
            center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
            center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
            await drainMainQueue()
            #expect(panel.orderOutCount == removals, "A Space transition must never detach immediately")
            try await Task.sleep(for: .milliseconds(400))
            #expect(panel.orderOutCount == removals,
                    "Detaching a surface already composited by WindowServer produces a visible blink")
            #expect(panel.orderingCount > orders)
            #expect(controller.presentation.isPresented)
            #expect(panel.contentView != nil)
        }
    }

    @Test func settledSpaceChangeRepairsOnlyAnOffscreenPanel() async throws {
        try await fixture(observeSystem: true, panelIsOnscreen: { _ in false }) { controller, panel, _, _ in
            controller.restore()
            controller.presentation.lifecycle.activityChanged(count: 1)
            await drainMainQueue()
            let orders = panel.orderingCount
            let removals = panel.orderOutCount
            NSWorkspace.shared.notificationCenter.post(
                name: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil
            )
            await drainMainQueue()
            #expect(panel.orderOutCount == removals)
            try await Task.sleep(for: .milliseconds(400))
            #expect(panel.orderOutCount == removals + 1)
            #expect(panel.orderingCount > orders)
            #expect(controller.presentation.isPresented)
        }
    }

    @Test func shutdownCancelsDelayedRecoveryAndCannotBeUndoneByShow() async throws {
        try await fixture { controller, panel, _, _ in
            controller.restore()
            controller.environmentChanged(retryAfterTransition: true)
            controller.shutdown()
            controller.restore()
            try await Task.sleep(for: .milliseconds(400))
            #expect(!controller.presentation.isPresented)
            #expect(panel.contentView == nil)
            #expect(!panel.isVisible)
        }
    }

    @Test func hiddenHostTeardownIsNotPostponedForeverByRepeatedRefreshes() async throws {
        try await fixture { controller, panel, _, _ in
            controller.restore()
            controller.presentation.lifecycle.activityChanged(count: 1)
            controller.presentation.lifecycle.dismiss()
            for _ in 0..<8 {
                controller.environmentChanged()
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(panel.contentView == nil)
            #expect(!panel.isVisible)
        }
    }

    @Test func oldHideAndPresentCallbacksCannotRemoveANewlyRestoredHost() async throws {
        try await fixture { controller, panel, _, _ in
            controller.restore()
            controller.presentation.lifecycle.activityChanged(count: 1)
            controller.presentation.lifecycle.dismiss()
            controller.environmentChanged()
            controller.restore()
            let restoredHost = try #require(panel.contentView)
            try await Task.sleep(for: .milliseconds(400))
            #expect(panel.contentView === restoredHost)
            #expect(controller.presentation.isPresented)
            #expect(panel.isVisible)
            #expect(controller.presentation.lifecycle.mode == .expanded)
        }
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
