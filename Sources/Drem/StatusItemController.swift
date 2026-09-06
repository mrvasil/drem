// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Copyright (C) 2026 drem contributors

import AppKit
import DremBrand
import Combine
import SwiftUI

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate, NSWindowDelegate {
    private let monitor: AgentMonitor
    private let keepAwake: KeepAwakeManager
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let presentation: AgentMenuPresentation
    private var settingsWindow: NSWindow?
    private var lastImageKey: String?
    private var wantsPopover = false
    private var cancellables = Set<AnyCancellable>()
    private var defaultsObserver: NSObjectProtocol?
    private var countdownTimer: Timer?

    init(monitor: AgentMonitor, keepAwake: KeepAwakeManager) {
        self.monitor = monitor
        self.keepAwake = keepAwake
        presentation = AgentMenuPresentation(monitor: monitor)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureStatusItem()
        configureApplicationMenu()
        configurePopover()
        bind()
        refresh()
    }

    deinit {
        countdownTimer?.invalidate()
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    func showPopover() {
        wantsPopover = true
        if NSApp.isActive {
            presentPopover()
        } else {
            // App activation is asynchronous. Present after didBecomeActive,
            // otherwise the focus change can immediately dismiss a transient popover.
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func presentPopover() {
        wantsPopover = false
        guard let button = statusItem.button else { return }
        installPopoverContentIfNeeded()
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func configureStatusItem() {
        statusItem.autosaveName = "DremMenuBarItem"
        statusItem.isVisible = true
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        popover.contentSize = NSSize(width: 340, height: 300)
    }

    private func configureApplicationMenu() {
        let main = NSMenu()
        let appMenu = NSMenu(title: "drem")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)
        let show = NSMenuItem(title: "Показать агентов", action: #selector(openPopover), keyEquivalent: "1")
        show.target = self
        appMenu.addItem(show)
        let settings = NSMenuItem(title: "Настройки…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Завершить drem", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        let windowMenu = NSMenu(title: "Окно")
        windowMenu.addItem(NSMenuItem(title: "Закрыть окно", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    private func installPopoverContentIfNeeded() {
        guard popover.contentViewController == nil else { return }
        let host = NSHostingController(
            rootView: StatusPanel(
                presentation: presentation, keepAwake: keepAwake,
                openSettings: { [weak self] in self?.showSettings() },
                refresh: { [weak self] in self?.refreshAgents() }
            )
        )
        if #available(macOS 13.0, *) {
            host.sizingOptions = .preferredContentSize
        }
        popover.contentViewController = host
    }

    func popoverDidClose(_ notification: Notification) {
        // No TimelineViews or repeating UI animations. Keep the small hosted
        // tree for instant reopening; only meaningful visible state changes.
    }

    @objc private func showSettings() {
        wantsPopover = false
        popover.performClose(nil)
        if settingsWindow == nil {
            let host = NSHostingController(rootView: KeepAwakeSettings(awake: keepAwake))
            let window = NSWindow(contentViewController: host)
            window.title = "Настройки drem"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 520, height: 560))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        // AppKit can retain a closed hosting view without SwiftUI onDisappear.
        // Never leave the global shortcut recorder armed behind a closed window.
        if KeepAwakeHotkeyManager.shared.isCapturing {
            KeepAwakeHotkeyManager.shared.cancelCapture()
        }
    }

    private func bind() {
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self, self.wantsPopover else { return }
                self.presentPopover()
            }
            .store(in: &cancellables)

        monitor.$snapshot
            .map { $0.workingCount }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        keepAwake.$isActive
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        keepAwake.$endDate
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        keepAwake.$isPausedForScreenLock
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            if UserDefaults.standard.bool(forKey: KeepAwakeDefaultsKey.rightClickToggle) {
                keepAwake.toggle()
            } else {
                showContextMenu()
            }
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showContextMenu() {
        guard let button = statusItem.button else { return }
        let menu = NSMenu()

        let awakeItem = NSMenuItem(
            title: "Не давать Mac уснуть",
            action: #selector(toggleKeepAwake),
            keyEquivalent: ""
        )
        awakeItem.target = self
        awakeItem.state = keepAwake.isActive ? .on : .off
        menu.addItem(awakeItem)

        let durations = NSMenu(title: "Длительность")
        for (title, minutes) in [
            ("15 минут", 15), ("30 минут", 30), ("1 час", 60),
            ("2 часа", 120), ("4 часа", 240), ("8 часов", 480),
            ("Бессрочно", 0),
        ] {
            let item = NSMenuItem(
                title: title,
                action: #selector(activateForDuration(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = minutes
            durations.addItem(item)
        }
        let durationItem = NSMenuItem(title: "Включить на…", action: nil, keyEquivalent: "")
        durationItem.submenu = durations
        menu.addItem(durationItem)

        menu.addItem(.separator())
        let openItem = NSMenuItem(
            title: "Открыть drem",
            action: #selector(openPopover),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        let refreshItem = NSMenuItem(
            title: "Обновить агентов",
            action: #selector(refreshAgents),
            keyEquivalent: ""
        )
        refreshItem.target = self
        menu.addItem(refreshItem)

        let settingsItem = NSMenuItem(title: "Настройки…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "Завершить drem",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleKeepAwake() {
        keepAwake.toggle()
    }

    @objc private func activateForDuration(_ sender: NSMenuItem) {
        keepAwake.activate(minutes: sender.tag)
    }

    @objc private func openPopover() {
        showPopover()
    }

    @objc private func refreshAgents() {
        Task { await monitor.refresh() }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func refresh() {
        guard let button = statusItem.button else { return }
        syncCountdownTimer()

        // Agent activity updates the count and tooltip, never the icon's appearance.
        let imageKey = keepAwake.isActive
            ? "active-\(KeepAwakeActiveIcon.current.rawValue)-\(KeepAwakeIconTint.current.rawValue)"
            : "inactive"
        if imageKey != lastImageKey {
            button.image = statusImage()
            lastImageKey = imageKey
        }
        let title = menuTitle
        if button.title != title { button.title = title }
        let description = tooltip
        if button.toolTip != description { button.toolTip = description }
        button.setAccessibilityLabel("drem. \(description)")
        button.imageHugsTitle = true
    }

    private func syncCountdownTimer() {
        let needed = keepAwake.isActive
            && keepAwake.endDate != nil
            && UserDefaults.standard.bool(forKey: KeepAwakeDefaultsKey.showCountdown)
        guard needed else {
            countdownTimer?.invalidate()
            countdownTimer = nil
            return
        }
        guard countdownTimer == nil else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    private func statusImage() -> NSImage? {
        Self.statusImage(
            isAwake: keepAwake.isActive,
            activeIcon: KeepAwakeActiveIcon.current, tint: KeepAwakeIconTint.current
        )
    }

    static func statusImage(isAwake: Bool,
                            activeIcon: KeepAwakeActiveIcon, tint: KeepAwakeIconTint) -> NSImage? {
        if !isAwake {
            return Self.idleStatusImage()
        }
        if activeIcon == .drem {
            return DremMark.menuImage(tint: Self.statusTint(tint))
        }
        return Self.statusSymbolImage(
            activeIcon.systemSymbolName, tint: Self.statusTint(tint)
        )
    }

    static func statusSymbolImage(_ symbolName: String, tint: NSColor?) -> NSImage? {
        guard let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
            return nil
        }
        let sizeConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        if let tint {
            let palette = NSImage.SymbolConfiguration(paletteColors: [tint])
            let image = base.withSymbolConfiguration(sizeConfiguration.applying(palette))
            image?.isTemplate = false
            return image
        }
        let image = base.withSymbolConfiguration(sizeConfiguration)
        image?.isTemplate = true
        return image
    }

    static func idleStatusImage() -> NSImage? {
        DremMark.menuImage()
    }

    static func statusTint(_ tint: KeepAwakeIconTint) -> NSColor? {
        switch tint {
        // sRGB fill sampled from the user's low-power battery reference (#F8D849).
        // Keep the stored "orange" preference compatible with existing installs.
        case .orange: return DremMark.batteryYellow
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .pink: return .systemPink
        case .none: return nil
        }
    }

    private var menuTitle: String {
        var parts: [String] = []
        let working = monitor.snapshot.workingCount
        if working > 0 { parts.append("\(working)") }

        if keepAwake.isActive,
           UserDefaults.standard.bool(forKey: KeepAwakeDefaultsKey.showCountdown) {
            if let end = keepAwake.endDate {
                let remaining = max(0, Int(end.timeIntervalSinceNow))
                let hours = remaining / 3600
                let minutes = (remaining % 3600) / 60
                parts.append(hours > 0 ? String(format: "%d:%02d", hours, minutes) : "\(max(1, minutes)) мин")
            } else {
                parts.append("∞")
            }
        }
        return parts.joined(separator: "  ")
    }

    private var tooltip: String {
        var lines: [String] = []
        let working = monitor.snapshot.workingCount
        lines.append(working == 0 ? "Агенты сейчас не работают" : "Работают агенты: \(working)")
        if keepAwake.isPausedForScreenLock {
            lines.append("Удержание сна приостановлено")
        } else if keepAwake.isActive {
            if let end = keepAwake.endDate {
                lines.append("Mac не уснёт до \(end.formatted(date: .omitted, time: .shortened))")
            } else {
                lines.append(keepAwake.sessionTrigger == .automation
                    ? "Mac не уснёт, пока действует автоматический режим"
                    : "Mac не уснёт, пока режим не выключен")
            }
        }
        return lines.joined(separator: "\n")
    }
}
