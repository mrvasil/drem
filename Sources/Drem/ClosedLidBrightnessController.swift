// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 drem contributors

import AppKit
import Combine

@MainActor
final class ClosedLidBrightnessController {
    static let recoveryKey = "closedLidBrightnessRestore"
    private(set) var isDimmed = false
    private(set) var lidClosed: Bool?
    private(set) var lastError: String? {
        didSet { if lastError != oldValue { onErrorChanged?(lastError) } }
    }
    var onErrorChanged: ((String?) -> Void)?

    private let defaults: UserDefaults
    private let brightness: BuiltinDisplayBrightness
    private let monitorSystem: Bool
    private var original: BuiltinBrightnessSnapshot?
    private var agentWakeActive = false
    private var stopped = false
    private var observer: LidStateObserver?
    private var screenObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var retry: DispatchWorkItem?
    private var retryAttempt = 0
    private var activitySubscription: AnyCancellable?

    init(defaults: UserDefaults = .standard, brightness: BuiltinDisplayBrightness = .live,
         monitorSystem: Bool = true) {
        self.defaults = defaults
        self.brightness = brightness
        self.monitorSystem = monitorSystem
        if let data = defaults.data(forKey: Self.recoveryKey),
           let saved = try? JSONDecoder().decode(BuiltinBrightnessSnapshot.self, from: data), saved.isValid {
            original = saved
            isDimmed = true
        }
    }

    deinit {
        retry?.cancel()
        observer?.stop()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    func bind(to manager: KeepAwakeManager) {
        onErrorChanged = { [weak manager] error in manager?.reportBrightnessError(error) }
        activitySubscription = Publishers.CombineLatest3(
            manager.$isActive, manager.$hasWorkingAgent, manager.$isPausedForScreenLock
        )
        .map { active, working, paused in active && working && !paused }
        .removeDuplicates()
        .sink { [weak self] active in self?.update(agentWakeActive: active) }
    }

    func start() {
        guard monitorSystem, observer == nil, !stopped else { return }
        let observer = LidStateObserver { [weak self] closed in
            DispatchQueue.main.async { self?.lidStateDidChange(closed) }
        }
        guard observer.start() else {
            lastError = "Не удалось включить отслеживание крышки для яркости"
            return
        }
        self.observer = observer
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.systemDidChange() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.systemDidChange() }
        }
        lidStateDidChange(observer.currentState)
    }

    func update(agentWakeActive: Bool) {
        guard !stopped, self.agentWakeActive != agentWakeActive else { return }
        self.agentWakeActive = agentWakeActive
        reconcile(resetRetries: true)
    }

    func lidStateDidChange(_ closed: Bool?) {
        guard !stopped, lidClosed != closed else { return }
        lidClosed = closed
        reconcile(resetRetries: true)
    }

    func systemDidChange() {
        guard !stopped else { return }
        if let observer { lidClosed = observer.currentState }
        reconcile(resetRetries: true)
    }

    func shutdown() {
        guard !stopped else { return }
        stopped = true
        activitySubscription = nil
        retry?.cancel()
        retry = nil
        observer?.stop()
        observer = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        // A quit must not strand the user at zero brightness without an observer.
        // On failure keep the persisted record for the next launch.
        restore()
    }

    private func reconcile(resetRetries: Bool) {
        if resetRetries { retry?.cancel(); retry = nil; retryAttempt = 0 }
        if lidClosed == false { restore() }
        else if lidClosed == true, agentWakeActive { dim() }
        // Task completion releases sleep elsewhere. Keep the closed panel dark
        // until opening, including if the system sleeps in the meantime.
    }

    private func dim() {
        if original == nil {
            guard let snapshot = brightness.read(), snapshot.isValid else {
                failed("Не удалось прочитать яркость встроенного экрана")
                return
            }
            guard snapshot.brightness > 0 else { return }
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            defaults.set(data, forKey: Self.recoveryKey)
            guard defaults.synchronize() else {
                failed("Не удалось сохранить яркость перед затемнением")
                return
            }
            original = snapshot
        }
        guard let original else { return }
        if let current = brightness.read(), current.displayUUID == original.displayUUID,
           current.brightness == 0 {
            isDimmed = true
            lastError = nil
            return
        }
        guard brightness.write(original, 0) else {
            failed("Не удалось затемнить встроенный экран")
            return
        }
        isDimmed = true
        lastError = nil
    }

    private func restore() {
        guard let original else { lastError = nil; return }
        guard brightness.write(original, original.brightness) else {
            failed("Не удалось восстановить яркость экрана — повторю при открытии или пробуждении")
            return
        }
        self.original = nil
        isDimmed = false
        lastError = nil
        defaults.removeObject(forKey: Self.recoveryKey)
        defaults.synchronize()
    }

    private func failed(_ message: String) {
        lastError = message
        // Bounded settling retries after a lid/display/wake event. No idle timer.
        guard monitorSystem, !stopped, retry == nil, retryAttempt < 3 else { return }
        let delay = [0.2, 0.7, 2.0][retryAttempt]
        retryAttempt += 1
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.retry = nil
            self.reconcile(resetRetries: false)
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
