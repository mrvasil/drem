// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 drem contributors

import AppKit
import Combine
import DremCore

enum AwayModeState: Equatable {
    case disabled
    case armed
    case locking
    case locked
    case failed
}

/// Security owns only the system lock. KeepAwakeManager remains the sole owner
/// of sleep assertions and releases them when the last agent finishes.
@MainActor
final class AwayModeController: ObservableObject {
    @Published private(set) var state: AwayModeState = .disabled
    @Published private(set) var lastError: String?

    private let keepAwake: KeepAwakeManager
    private let locker: SystemScreenLocker
    private let isScreenLocked: () -> Bool
    private let schedule: (TimeInterval, DispatchWorkItem) -> Void
    private weak var lidMonitor: LidStateMonitor?
    private var lidObservation: UUID?
    private var lockObservers: [NSObjectProtocol] = []
    private var modeSubscription: AnyCancellable?
    private var verification: DispatchWorkItem?
    private var lastLidState: Bool?
    private var lidMonitoringAvailable = false
    private var started = false

    private static let screenLockNotification = Notification.Name("com.apple.screenIsLocked")
    private static let screenUnlockNotification = Notification.Name("com.apple.screenIsUnlocked")

    init(
        keepAwake: KeepAwakeManager,
        locker: SystemScreenLocker = .live,
        isScreenLocked: @escaping () -> Bool = {
            KeepAwakeAutomationSupport.isScreenLocked(
                sessionDictionary: CGSessionCopyCurrentDictionary() as? [String: Any]
            )
        },
        schedule: @escaping (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    ) {
        self.keepAwake = keepAwake
        self.locker = locker
        self.isScreenLocked = isScreenLocked
        self.schedule = schedule
    }

    func start(lidMonitor: LidStateMonitor) {
        guard !started else { return }
        self.lidMonitor = lidMonitor
        lidMonitoringAvailable = true
        lidObservation = lidMonitor.observe { [weak self] state in
            self?.lidStateDidChange(state)
        }
        startCommon(observeSystemLock: true)
    }

    /// Keeps unit tests deterministic and prevents them from touching the live
    /// distributed session or physical lid service.
    func startWithoutSystemObservers() {
        guard !started else { return }
        lidMonitoringAvailable = true
        startCommon(observeSystemLock: false)
    }

    func shutdown() {
        verification?.cancel()
        verification = nil
        modeSubscription = nil
        if let lidObservation { lidMonitor?.removeObserver(lidObservation) }
        lidObservation = nil
        lidMonitor = nil
        let center = DistributedNotificationCenter.default()
        for observer in lockObservers { center.removeObserver(observer) }
        lockObservers.removeAll()
        started = false
    }

    func lidMonitoringDidFail() {
        lidMonitoringAvailable = false
        guard keepAwake.awayModeEnabled else { return }
        fail("Не удалось отслеживать закрытие крышки")
    }

    func lidStateDidChange(_ closed: Bool?) {
        let previous = lastLidState
        lastLidState = closed
        guard keepAwake.awayModeEnabled else { return }
        guard closed == true, previous != true else { return }
        requestLock()
    }

    func screenLockStateDidChange(locked: Bool) {
        verification?.cancel()
        verification = nil
        if locked {
            state = .locked
            lastError = nil
        } else if keepAwake.awayModeEnabled {
            state = availabilityError == nil ? .armed : .failed
            lastError = availabilityError
        } else {
            state = .disabled
            lastError = nil
        }
    }

    private var availabilityError: String? {
        guard lidMonitoringAvailable else { return "Не удалось отслеживать закрытие крышки" }
        guard locker.canRequestPrimary() || locker.canRequestFallback() else {
            return "Системная блокировка недоступна — разрешите drem в Универсальном доступе"
        }
        return nil
    }

    private func startCommon(observeSystemLock: Bool) {
        started = true
        if observeSystemLock {
            let center = DistributedNotificationCenter.default()
            lockObservers = [
                center.addObserver(
                    forName: Self.screenLockNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.screenLockStateDidChange(locked: true) }
                },
                center.addObserver(
                    forName: Self.screenUnlockNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.screenLockStateDidChange(locked: false) }
                },
            ]
        }
        modeSubscription = keepAwake.$awayModeEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in self?.modeDidChange(enabled) }
    }

    private func modeDidChange(_ enabled: Bool) {
        verification?.cancel()
        verification = nil
        guard enabled else {
            state = .disabled
            lastError = nil
            return
        }
        if isScreenLocked() {
            state = .locked
            lastError = nil
        } else if let error = availabilityError {
            fail(error)
        } else if lastLidState == true {
            requestLock()
        } else {
            state = .armed
            lastError = nil
        }
    }

    private func requestLock() {
        verification?.cancel()
        verification = nil
        if isScreenLocked() {
            screenLockStateDidChange(locked: true)
            return
        }
        state = .locking
        lastError = nil
        if locker.requestPrimary() {
            scheduleVerification(afterPrimary: true)
        } else if locker.requestFallback() {
            scheduleVerification(afterPrimary: false)
        } else {
            fail(availabilityError ?? "Не удалось вызвать системную блокировку Mac")
        }
    }

    private func scheduleVerification(afterPrimary: Bool) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.verification = nil
            if self.isScreenLocked() {
                self.screenLockStateDidChange(locked: true)
            } else if afterPrimary, self.locker.requestFallback() {
                self.scheduleVerification(afterPrimary: false)
            } else {
                self.fail("macOS не подтвердила блокировку экрана")
            }
        }
        verification = work
        schedule(0.8, work)
    }

    private func fail(_ message: String) {
        verification?.cancel()
        verification = nil
        state = .failed
        lastError = message
    }
}
